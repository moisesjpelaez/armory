// Lights and shadows for the lighting shader and the shadow pass:
// - arm_get_light() unpacks a light from the uniforms RasterLights.hx fills.
// - arm_shadow() tells how much of a light reaches a point past the shadow casters.
// - arm_light() turns a light into an ArmLamp: its direction, intensity and outline.
// lighting.py pastes this file after vpraster_specular.glsl. The sizes, limits and
// light kinds are #defines that lighting.py reads from the engine's Haxe sources.
//
// Soft shadows follow PCSS. Each frame takes only a few samples, in a pattern that
// changes every frame; they rely on temporal anti-aliasing to average them.

// One Blender light, as RasterLights.hx packs it
struct LightData
{
    int kind;               // ARM_LIGHT_SUN, ARM_LIGHT_POINT, ARM_LIGHT_SPOT or ARM_LIGHT_AREA
    vec3 position;
    vec3 direction;         // where the light travels
    vec3 color;
    float energy;           // sun: W/m2; point, spot, area: W
    float spotSize;         // full cone angle (radians)
    float spotBlend;        // 0..1
    float influenceRadius;  // metres, 0 = none
    float firstShadowView;  // index into u_armShadows, -1 = no shadow
    float shadowViewCount;
    float shadowChannel;    // channel of the shadow pass's image, -1 = none
    float radius;           // sun: half angle (radians); point, spot: metres
    float areaWidth;
    float areaHeight;
    bool areaEllipse;       // else a rectangle
    vec3 tangent;           // area light's local X axis (its width)
};


uniform vec4 u_lightPacked[MAX_LIGHT_SOURCES * ARM_LIGHT_VEC4S];
uniform int u_numActiveLightSources;

// Decodes a normal stored in octahedral form in the material images (arm_gbuffer.glsl
// stores the shading normal and the triangle's own normal this way)
vec3 arm_decode_octahedral(vec2 e)
{
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

// Unpacks light `index`. Each light takes ARM_LIGHT_VEC4S vec4s, in the layout that
// RasterLights.hx's header lists. The array is of vec4s because Direct3D pads each
// element of a float array to 16 bytes.
LightData arm_get_light(int index)
{
    vec4 a = u_lightPacked[index * ARM_LIGHT_VEC4S + 0];
    vec4 b = u_lightPacked[index * ARM_LIGHT_VEC4S + 1];
    vec4 c = u_lightPacked[index * ARM_LIGHT_VEC4S + 2];
    vec4 d = u_lightPacked[index * ARM_LIGHT_VEC4S + 3];
    LightData light;
    light.kind = int(a.x);
    light.spotSize = a.y;
    light.spotBlend = a.z;
    light.shadowViewCount = a.w;
    light.position = b.xyz;
    light.energy = b.w;
    light.direction = c.xyz;
    light.influenceRadius = c.w;
    light.color = d.xyz;
    light.firstShadowView = d.w;
    vec4 e = u_lightPacked[index * ARM_LIGHT_VEC4S + 4];
    vec4 f = u_lightPacked[index * ARM_LIGHT_VEC4S + 5];
    light.radius = e.x;
    light.areaWidth = e.y;
    light.areaHeight = e.z;
    light.areaEllipse = e.w > 0.5;
    light.tangent = f.xyz;
    light.shadowChannel = f.w;
    return light;
}

// Shadow lookup

#ifdef ARM_SHADOWS_FROM_PASS
// ARM_SHADOWS_FROM_PASS reads the shadows from the shadow pass's image and leaves out
// the shadow code below. It leaves out code this frame doesn't need, because unused
// code still slows the shader down. lighting.py's docstring lists the versions.
// The image has the same size as the lit image. Each channel holds the visibility
// from one shadow-casting light (LightData.shadowChannel), up to 4 lights.
// The shadow pass (vpraster_shadow_pass.glsl) writes it with the code below.
uniform sampler2D u_armShadowVisibility;
#else
// Shadow views, ARM_SHADOW_VIEW_VEC4S vec4s each: rows U, V, depth and W of the view's
// matrix, then its tile in the atlas, then extra values (see RasterShadows.hx).
// vec4s, because Direct3D pads each element of a float array to 16 bytes.
uniform vec4 u_armShadows[ARM_MAX_SHADOW_VIEWS * ARM_SHADOW_VIEW_VEC4S];
// x: 1 / atlas size in texels
// y: width of sun penumbras, relative to the physical one
// z: frame number for the noise
// w: width of point, spot and area light penumbras, relative to the physical one
uniform vec4 u_armShadowInfo;
uniform sampler2D u_armShadowMap;

// Shadow map reads per pixel and frame, to find the blockers and then to filter.
// They are few: the pattern turns and its radii shift every frame, and temporal
// anti-aliasing averages the frames into a smooth penumbra. Eevee likewise builds
// its soft shadows up over its samples.
#define ARM_BLOCKER_SAMPLES 8
#define ARM_FILTER_SAMPLES 12

// Reads the shadow atlas at a texel. u_armShadowMap is the atlas's depth buffer
// (RasterShadows draws depth only). It holds each view's linear depth 0..1, so this
// shader needs no conversion: an orthographic tile matrix gives linear depth as is,
// and perspective views write it per pixel (vpraster_shadow_perspective.frag.glsl).
float arm_shadow_depth(vec2 texel)
{
    return textureLod(u_armShadowMap, (texel + 0.5) * u_armShadowInfo.x, 0.0).r;
}

// Depth at tile coordinates `uv`, kept inside the tile
float arm_shadow_depth_uv(vec4 tile, vec2 uv, float margin)
{
    uv = clamp(uv, vec2(margin), vec2(1.0 - margin));
    return textureLod(u_armShadowMap, tile.xy + uv * tile.zw, 0.0).r;
}

// Sample points on a unit disc (Vogel spiral): point i of n lies at radius
// sqrt((i + shift) / n) and angle i times the golden angle (2.39996323 rad), plus a
// turn per pixel. ARM_GOLDEN_TURN is the cosine and sine of the golden angle: the
// loops turn the direction by it instead of calling cos and sin per point.
// Rule: do not replace this with a constant array of points indexed in the loop.
// Direct3D's shader compiler (fxc, also used by browsers through ANGLE) then takes
// very long to compile the lighting shader.
const vec2 ARM_GOLDEN_TURN = vec2(-0.73736888, 0.67549029);

// `p` turned by the angle whose cosine and sine are `cs`
vec2 arm_rotate(vec2 p, vec2 cs)
{
    return vec2(p.x * cs.x - p.y * cs.y, p.x * cs.y + p.y * cs.x);
}

// Exact depth of the receiving surface at tile coordinates `uv` in a perspective view:
// where the ray from the light through `uv` meets the receiver's plane (normal N).
// Returns `fallback` when the ray misses the plane.
// The view's frame: `axis` along it, `right` and `up` across it, and `k` is tile uv
// per unit of tan(angle). `planeDistance` is the receiver's distance along the axis
// times dot(N, its ray).
float arm_plane_depth(vec2 uv, vec3 axis, vec3 right, vec3 up, float k, vec3 N, float planeDistance,
                      float nearDistance, float depthRange, float fallback)
{
    vec3 d = axis + ((uv.x - 0.5) / k) * right - ((uv.y - 0.5) / k) * up;
    float nd = dot(N, d);
    if (abs(nd) < 1e-5 || planeDistance / nd <= 0.0) return fallback;
    return (planeDistance / nd - nearDistance) / depthRange;
}

// Visibility of `position` in one shadow view, from 0 (in shadow) to 1 (lit).
// `inside` is false when the point is outside the view's tile; the result is then 1.
//
// Soft shadows follow PCSS (Fernando 2005). First, the average depth of the blockers
// near the point gives the width of the penumbra. Then a disc of that radius filters
// the shadow; as in Eevee, penumbras have disc-shaped edges. The penumbra radius:
//   sun (`size` = half angle): d * tan(size) * u_armShadowInfo.y, for a blocker
//     d metres away
//   local light (`size` = radius in metres): size * (dr - db) / db * u_armShadowInfo.w,
//     for receiver and blocker distances dr and db
//
// geomNormal is the triangle's own normal, turned to the light's side. The point moves
// along it before the lookup (normal offset), because the shadow map holds the flat
// triangles, not the smooth shading normal.
// arm_shadow() computes the values all views of a light share once: offsetScale (the
// normal offset, larger at grazing light) and sunSpread (tan of the sun's half angle).
// `strict`: a sun cascade with a coarser one behind it.
float arm_shadow_view(int view, vec3 position, vec3 geomNormal, float offsetScale, float sunSpread, float size, bool strict, out bool inside)
{
    // The view's rows, as RasterShadows.hx lists them
    int o = view * ARM_SHADOW_VIEW_VEC4S;
    vec4 rowU = u_armShadows[o + 0];
    vec4 rowV = u_armShadows[o + 1];
    vec4 rowDepth = u_armShadows[o + 2];
    vec4 rowW = u_armShadows[o + 3];
    vec4 tile = u_armShadows[o + 4];
    vec4 extra = u_armShadows[o + 5];
    float uvPerMetreAtW1 = extra.x;
    float nearDistance = extra.y; // metres; suns: 0 (their depth range starts at the nearest caster)
    float depthRange = extra.z;   // metres per depth unit
#ifdef ARM_SUN_SHADOWS_ONLY
    // ARM_SUN_SHADOWS_ONLY: only suns cast shadows, so every view is orthographic and
    // the perspective code is left out. It leaves out code this frame doesn't need,
    // because unused code still slows the shader down (lighting.py lists the versions).
    const bool perspective = false;
#else
    bool perspective = extra.w > 0.5;
#endif
    float tileTexels = tile.z / u_armShadowInfo.x;

    // The size of one shadow texel in metres at the shaded point sets the normal
    // offset (scaled by offsetScale)
#ifdef ARM_SUN_SHADOWS_ONLY
    // Orthographic views: w is 1 (row W is 0, 0, 0, 1)
    const float w0 = 1.0;
#else
    float w0 = dot(rowW.xyz, position) + rowW.w;
    inside = w0 > nearDistance;
    if (!inside) return 1.0;
#endif
    float uvPerMetre = uvPerMetreAtW1 / w0;
    float texelWorld = 1.0 / (uvPerMetre * tileTexels);
    vec3 p = position + geomNormal * texelWorld * offsetScale;
#ifdef ARM_SUN_SHADOWS_ONLY
    const float w = 1.0;
#else
    float w = dot(rowW.xyz, p) + rowW.w;
#endif
    vec3 uvw = vec3((dot(rowU.xyz, p) + rowU.w) / w, (dot(rowV.xyz, p) + rowV.w) / w, dot(rowDepth.xyz, p) + rowDepth.w);

    // Receiver distance from the light (local) or from the start of the depth range (sun)
    float receiver = uvw.z * depthRange + nearDistance;
    // The widest penumbra to expect here, in tile uv. Local lights: the light's radius
    // seen from a blocker a quarter of the way from the light to the receiver (or at
    // the near plane, if that is farther).
    float softUV = perspective
        ? size / max(0.25 * receiver, nearDistance) * uvPerMetreAtW1
        : sunSpread * u_armShadowInfo.y * receiver * uvPerMetre;

    // A tile covers a box (sun) or a frustum (local light), so the point must also be
    // inside its depth range. With `strict`, the whole soft shadow kernel must fit in
    // the tile, else samples clamped at its edge draw false shadows; the coarser cascade
    // takes the point instead. The search radius is capped at 0.1 of the tile.
    float margin = 1.0 / tileTexels + (strict ? min(softUV, 0.1) : 0.0);
    inside = all(greaterThan(uvw.xy, vec2(margin))) && all(lessThan(uvw.xy, vec2(1.0 - margin))) && uvw.z < 1.0;
    if (!inside) return 1.0;
    margin = 1.0 / tileTexels;
    // Depth bias of half a texel towards the light, so a lit surface does not shadow
    // itself
    float depth = uvw.z - texelWorld / depthRange * 0.5;
    // Soft shadow when the penumbra can be wider than 1.5 texels, else a hard shadow
    if (softUV > 1.5 / tileTexels)
    {
        // A rotation and a radial shift per pixel and frame (interleaved gradient noise).
        // Over the frames that temporal anti-aliasing averages, the few reads cover the
        // whole disc. The noise is per pixel on purpose: the same offset for every pixel
        // would make the remaining noise move as a whole and flicker more.
        float angle = 2.0 * M_PI * arm_ign(gl_FragCoord.xy, u_armShadowInfo.z);
        vec2 turn = vec2(cos(angle), sin(angle));
        float shift = arm_ign(gl_FragCoord.xy + vec2(47.0, 17.0), u_armShadowInfo.z);
        // Receiver plane depth bias (Isidoro, GDC 2006). Each sample compares against
        // the receiver's own depth at that offset, found from its triangle normal, so
        // a sloped surface does not shadow itself inside the filter disc.
        // Orthographic views use a linear slope. Perspective views use the exact
        // ray-plane depth (arm_plane_depth).
        vec2 depthSlope = vec2(0.0); // depth units per tile uv (orthographic)
        vec3 axis = vec3(0.0), right = vec3(0.0), up = vec3(0.0); // perspective frame
        float planeDistance = 0.0;
        if (perspective)
        {
            // The view's axis is row W. Rows U and V are axis / 2 + k * right and
            // axis / 2 - k * up, which gives right and up.
            axis = rowW.xyz;
            right = (rowU.xyz - 0.5 * axis) / uvPerMetreAtW1;
            up = (0.5 * axis - rowV.xyz) / uvPerMetreAtW1;
            vec3 ray = axis + ((uvw.x - 0.5) / uvPerMetreAtW1) * right - ((uvw.y - 0.5) / uvPerMetreAtW1) * up;
            planeDistance = w * dot(geomNormal, ray);
        }
        else
        {
            // The normal across the tile (in uv per metre) and along the depth axis
            vec2 nUV = vec2(dot(geomNormal, rowU.xyz), dot(geomNormal, rowV.xyz)) / uvPerMetre;
            float nz = dot(geomNormal, normalize(rowDepth.xyz));
            // Kept away from 0, which limits the slope of surfaces seen edge-on
            nz = nz < 0.0 ? min(nz, -0.05) : max(nz, 0.05);
            depthSlope = -nUV / (nz * uvPerMetre * depthRange);
        }
        // Remaining bias: two texels along the slope plus one texel in depth, chosen so
        // that sloped surfaces do not shadow themselves
        float planeBias = 2.0 / tileTexels * length(depthSlope) + texelWorld / depthRange;

        // 1. Find the blockers within the widest penumbra (at most 0.1 of the tile)
        float search = min(softUV, 0.1);
        vec2 dir = turn; // direction of point i (ARM_GOLDEN_TURN)
        float blockerSum = 0.0;
        float blockers = 0.0;
        for (int i = 0; i < ARM_BLOCKER_SAMPLES; i++)
        {
            vec2 offset = sqrt((float(i) + shift) / float(ARM_BLOCKER_SAMPLES)) * search * dir;
            dir = arm_rotate(dir, ARM_GOLDEN_TURN);
            float d = arm_shadow_depth_uv(tile, uvw.xy + offset, margin);
            float expected = perspective ? arm_plane_depth(uvw.xy + offset, axis, right, up, uvPerMetreAtW1, geomNormal, planeDistance, nearDistance, depthRange, depth) : depth + dot(depthSlope, offset);
            if (d < expected - planeBias)
            {
                blockerSum += d;
                blockers += 1.0;
            }
        }
        if (blockers == 0.0) return 1.0;

        // 2. The penumbra's radius from the blockers' average depth.
        // 3. The share of lit samples over a disc of that radius.
        float blockerDepth = blockerSum / blockers;
        float radius;
        if (perspective)
        {
            float blocker = max(blockerDepth * depthRange + nearDistance, 1e-4);
            radius = size * (receiver - blocker) / blocker * u_armShadowInfo.w * uvPerMetre;
        }
        else
        {
            radius = sunSpread * u_armShadowInfo.y * (depth - blockerDepth) * depthRange * uvPerMetre;
        }
        radius = max(radius, 1.0 / tileTexels);
        dir = turn;
        float lit = 0.0;
        for (int i = 0; i < ARM_FILTER_SAMPLES; i++)
        {
            vec2 offset = sqrt((float(i) + shift) / float(ARM_FILTER_SAMPLES)) * radius * dir;
            dir = arm_rotate(dir, ARM_GOLDEN_TURN);
            float d = arm_shadow_depth_uv(tile, uvw.xy + offset, margin);
            float expected = perspective ? arm_plane_depth(uvw.xy + offset, axis, right, up, uvPerMetreAtW1, geomNormal, planeDistance, nearDistance, depthRange, depth) : depth + dot(depthSlope, offset);
            lit += expected - planeBias <= d ? 1.0 : 0.0;
        }
        return lit / float(ARM_FILTER_SAMPLES);
    }

    // Hard shadow: four depth comparisons, blended bilinearly for a smooth edge
    vec2 texel = (tile.xy + uvw.xy * tile.zw) / u_armShadowInfo.x - 0.5;
    vec2 base = floor(texel);
    vec2 weight = texel - base;
    vec4 lit = vec4(
        depth <= arm_shadow_depth(base) ? 1.0 : 0.0,
        depth <= arm_shadow_depth(base + vec2(1.0, 0.0)) ? 1.0 : 0.0,
        depth <= arm_shadow_depth(base + vec2(0.0, 1.0)) ? 1.0 : 0.0,
        depth <= arm_shadow_depth(base + vec2(1.0, 1.0)) ? 1.0 : 0.0);
    return mix(mix(lit.x, lit.y, weight.x), mix(lit.z, lit.w, weight.x), weight.y);
}
#endif

// Visibility of `position` from the light, from 0 (in shadow) to 1 (lit). `toLight` is
// the unit direction towards the light. The light's first view that contains the
// point answers: for suns the finest cascade (one view with an orthographic camera),
// for point and area lights the cube face; a spot light has one view.
float arm_shadow(LightData light, vec3 position, vec3 geomNormal, vec3 toLight)
{
#ifdef ARM_SHADOWS_FROM_PASS
    if (light.shadowChannel < 0.0) return 1.0;
    vec4 visibility = texelFetch(u_armShadowVisibility, ivec2(gl_FragCoord.xy), 0);
    int slot = int(light.shadowChannel);
    return slot == 0 ? visibility.x : slot == 1 ? visibility.y : slot == 2 ? visibility.z : visibility.w;
#else
    if (light.firstShadowView < 0.0) return 1.0;
#ifdef ARM_SUN_SHADOWS_ONLY
    // This version can be drawn while spot, point or area lights cast shadows: for the
    // few frames until the version with their shadow code has loaded
    // (RenderPathViewportRaster). Those lights stay unshadowed meanwhile.
    if (light.kind != ARM_LIGHT_SUN) return 1.0;
#endif
    int first = int(light.firstShadowView);
    int count = int(light.shadowViewCount);
    float size = light.kind == ARM_LIGHT_AREA ? 0.5 * max(light.areaWidth, light.areaHeight) : light.radius;
    // The triangle's side that faces the light, because the normal offset must move
    // the point towards the light. A two-sided surface lit from behind casts a shadow
    // on itself, and an offset into it would shadow whole rows of texels.
    vec3 facing = dot(geomNormal, toLight) < 0.0 ? -geomNormal : geomNormal;
    float nl = clamp(dot(facing, toLight), 0.0, 1.0);
    // Normal offset in shadow texels: a quarter texel facing the light, up to one texel
    // at grazing light, where a surface is most likely to shadow itself
    float offsetScale = 0.25 + 0.75 * sqrt(1.0 - nl * nl);
    // Sun: tan of the half angle, kept below 90 degrees (as in arm_lamp_cone). Past it
    // the tangent turns negative and the soft shadow would become hard.
    float sunSpread = tan(min(size, 1.5));
    for (int i = 0; i < 6; i++)
    {
        if (i >= count) break;
        bool inside;
        float visibility = arm_shadow_view(first + i, position, facing, offsetScale, sunSpread, size, light.kind == ARM_LIGHT_SUN && i < count - 1, inside);
        if (inside) return visibility;
    }
    return 1.0;
#endif
}

// Blender's lights, as arm_light() below models them (light kinds: ARM_LIGHT_*):
//   sun    Strength is irradiance in W/m2. `direction` is where the light travels.
//   point  Power P in W: radiant intensity P / (4 pi), inverse-square falloff.
//   spot   A point light masked by a cone. spotSize is the full cone angle;
//          spotBlend softens the edge inwards.
//   area   Power P in W from a one-sided flat (Lambertian) emitter facing `direction`.
// Point, spot and area lights fade out towards their influence radius r (from Eevee's
// light_threshold or the light's custom distance; 0 = no limit), as in Eevee:
// (1 - (d / r)^4)^2 at distance d.
// Shadows come from arm_shadow() (above), for lights with a shadow view.
// Highlights use the lamp's outline as seen from the shaded point (lamp.verts, see
// vpraster_specular.glsl). Lamps smaller than ARM_MIN_OUTLINE_ANGLE count as points,
// and so does every lamp with ARM_POINT_LAMPS.

// Polygons of ARM_LAMP_VERTS sides stand in for circles and ellipses. This scales the
// polygon's radius so that its area equals the circle's: sqrt(pi / (n/2 sin(2 pi / n)))
const float ARM_EQUAL_AREA = sqrt(M_PI / (0.5 * float(ARM_LAMP_VERTS) * sin(2.0 * M_PI / float(ARM_LAMP_VERTS))));

// A round lamp (sun, point, spot): the cone of half angle `a` around `axis`, as a
// polygon of unit directions
void arm_lamp_cone(inout ArmLamp lamp, vec3 axis, float a)
{
#ifdef ARM_POINT_LAMPS
    // Every lamp is a point here (RasterLights.outlines is false).
    // Rule: set every field of the lamp, because Direct3D's compiler rejects a struct
    // passed out with fields left unset.
    lamp.count = 0;
    lamp.solidAngle = 0.0;
    lamp.coneAxis = axis;
    lamp.coneSinSq = 0.0;
#else
    if (a < ARM_MIN_OUTLINE_ANGLE)
    {
        lamp.count = 0;
        return;
    }
    vec3 helper = abs(axis.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 x = normalize(cross(helper, axis));
    vec3 y = cross(axis, x);
    float t = tan(min(a, 1.5)) * ARM_EQUAL_AREA;
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        float phi = float(i) * (2.0 * M_PI / float(ARM_LAMP_VERTS));
        lamp.verts[i] = normalize(axis + t * (cos(phi) * x + sin(phi) * y));
    }
    lamp.count = ARM_LAMP_VERTS;
    lamp.solidAngle = 2.0 * M_PI * (1.0 - cos(a));
    lamp.coneAxis = axis;
    lamp.coneSinSq = sin(a) * sin(a);
#endif
}

// The outline of an area light (rectangle or ellipse), as directions from `position`
void arm_lamp_area(inout ArmLamp lamp, LightData light, vec3 position)
{
    lamp.coneSinSq = 0.0;
#ifdef ARM_POINT_LAMPS
    // This version can be drawn with area lights for the few frames until the version
    // with outlines has loaded (RenderPathViewportRaster). The light is then a point,
    // and its solid angle is the area seen from `position`, because the intensity in
    // arm_light() multiplies by it.
    lamp.count = 0;
    lamp.coneAxis = light.direction;
    vec3 toPoint = position - light.position;
    float area = !light.areaEllipse ? light.areaWidth * light.areaHeight : 0.25 * M_PI * light.areaWidth * light.areaHeight;
    lamp.solidAngle = area * max(dot(normalize(toPoint), light.direction), 0.0) / max(dot(toPoint, toPoint), 1e-8);
#else
    vec3 x = light.tangent * (0.5 * light.areaWidth);
    vec3 y = cross(light.direction, light.tangent) * (0.5 * light.areaHeight);
    if (!light.areaEllipse)
    {
        lamp.verts[0] = normalize(light.position - x - y - position);
        lamp.verts[1] = normalize(light.position + x - y - position);
        lamp.verts[2] = normalize(light.position + x + y - position);
        lamp.verts[3] = normalize(light.position - x + y - position);
        lamp.count = 4;
        lamp.solidAngle = arm_polygon_solid_angle(lamp, 4);
        return;
    }
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        float phi = float(i) * (2.0 * M_PI / float(ARM_LAMP_VERTS));
        lamp.verts[i] = normalize(light.position + ARM_EQUAL_AREA * (cos(phi) * x + sin(phi) * y) - position);
    }
    lamp.count = ARM_LAMP_VERTS;
    lamp.solidAngle = arm_polygon_solid_angle(lamp, ARM_LAMP_VERTS);
#endif
}

// How much of a point, spot or area light reaches `position`, before shadows: the
// fade towards the influence radius, the spot cone, and the area light's front side.
// `direction` is the unit vector from `position` to the light, `distanceSq` the squared
// distance. The shadow pass uses it too, to skip the same points
// (vpraster_shadow_pass.glsl).
float arm_light_reach(LightData light, vec3 position, vec3 direction, float distanceSq)
{
    float reach = 1.0;
    if (light.influenceRadius > 0.0)
    {
        float x = distanceSq / (light.influenceRadius * light.influenceRadius);
        reach = clamp(1.0 - x * x, 0.0, 1.0);
        reach *= reach;
    }
    if (light.kind == ARM_LIGHT_SPOT)
    {
        float cosAngle = dot(-direction, light.direction);
        float cosEdge = cos(light.spotSize * 0.5);
        float blendWidth = max((1.0 - cosEdge) * light.spotBlend, 1e-6);
        reach *= smoothstep(0.0, 1.0, (cosAngle - cosEdge) / blendWidth);
    }
    if (light.kind == ARM_LIGHT_AREA && dot(position - light.position, light.direction) <= 0.0)
        reach = 0.0; // one-sided emitter, seen from behind
    return reach;
}

// The lamp that light `light` makes at `position`: direction, intensity (with reach
// and shadow) and outline. geomNormal is the triangle's own normal, for the shadow.
void arm_light(LightData light, vec3 position, vec3 geomNormal, out ArmLamp lamp)
{
    if (light.kind == ARM_LIGHT_SUN)
    {
        lamp.direction = -light.direction;
        lamp.intensity = light.color * (light.energy * arm_shadow(light, position, geomNormal, lamp.direction));
        arm_lamp_cone(lamp, lamp.direction, light.radius);
        return;
    }

    vec3 toLight = light.position - position;
    float distanceSq = max(dot(toLight, toLight), 1e-8);
    lamp.direction = toLight * inversesqrt(distanceSq);

    // Where no light reaches, skip the outline and the shadow
    float reach = arm_light_reach(light, position, lamp.direction, distanceSq);
    if (reach <= 0.0)
    {
        // This also keeps the outline away from points on an area light's own plane.
        // There the outline is degenerate, and its NaN solid angle times zero reach
        // would still be NaN.
        lamp.intensity = vec3(0.0);
        lamp.count = 0;
        return;
    }

    if (light.kind == ARM_LIGHT_AREA)
        arm_lamp_area(lamp, light, position);
    else
        // As in Eevee, a point or spot lamp is a disc of its radius facing the shaded
        // point, not a sphere (irradiance P / (4 pi (d^2 + r^2)))
        arm_lamp_cone(lamp, lamp.direction, atan(light.radius * inversesqrt(distanceSq)));
    float shadow = reach * arm_shadow(light, position, geomNormal, lamp.direction);

    // A lamp with an outline gets radiance x the outline's solid angle as its intensity.
    // The averages over the outline (arm_lamp_cosine, arm_lamp_lobe) then give the
    // exact integral.
    if (light.kind == ARM_LIGHT_AREA)
    {
        // One-sided Lambertian emitter: radiance P / (pi area)
        float area = !light.areaEllipse ? light.areaWidth * light.areaHeight : 0.25 * M_PI * light.areaWidth * light.areaHeight;
        float radiance = light.energy / (M_PI * max(area, 1e-8));
        lamp.intensity = light.color * (radiance * lamp.solidAngle * shadow);
    }
    else if (lamp.count > 0)
    {
        // Disc of radius r with the sphere light's radiance P / (4 pi^2 r^2)
        float radiance = light.energy / (4.0 * M_PI * M_PI * light.radius * light.radius);
        lamp.intensity = light.color * (radiance * lamp.solidAngle * shadow);
    }
    else
    {
        lamp.intensity = light.color * (light.energy * shadow / (4.0 * M_PI * distanceSq));
    }
}
