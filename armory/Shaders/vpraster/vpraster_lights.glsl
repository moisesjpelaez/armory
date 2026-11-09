// Lights and shadows of the Viewport renderer's lighting pass (lighting.py puts
// vpraster_specular.glsl before this file). Sizes and light kinds are #defines
// from lighting.py, read from the engine's Haxe sources.

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

// A normal stored in the material images (arm_gbuffer.glsl): the shading normal and
// the triangle's own, which the shadow lookup offsets along
vec3 arm_decode_octahedral(vec2 e)
{
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

// Unpacks light `index`: ARM_LIGHT_VEC4S vec4 per light, in the order written in
// RasterLights.hx (its header lists the layout)
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
// The visibility of each pixel from up to 4 shadow-casting lights, one channel each
// (LightData.shadowChannel), written by the shadow pass (vpraster_shadow_pass.glsl) with
// the code below. The lighting pass reads it instead of running that code: the code's
// mere presence made the whole lighting shader slower (Larimar at 1920 x 1080 on an
// AMD integrated GPU: shadows 3.05 ms inside it, 1.86 ms as a pass of their own).
// Same size as the lit image: read at this pixel.
uniform sampler2D u_armShadowVisibility;
#else
// Shadow views: ARM_SHADOW_VIEW_VEC4S vec4 each (rows U, V, depth, W, tile, extra),
// as RasterShadows.hx lists them
uniform vec4 u_armShadows[ARM_MAX_SHADOW_VIEWS * ARM_SHADOW_VIEW_VEC4S];
// x: 1 / atlas size in texels
// y: width of sun penumbras, relative to the physical one
// z: frame number for the noise
// w: width of point, spot and area light penumbras, relative to the physical one
uniform vec4 u_armShadowInfo;
uniform sampler2D u_armShadowMap;

// Soft shadow reads per pixel and frame. The pattern turns and its radii shift every
// frame, and TAA averages the frames, as Eevee builds its soft shadows up over its
// samples (measured: at 1 sample its penumbras are noisy, at 16 they match 64).
// 16 + 24 reads per frame cost Larimar 4.6 ms on an AMD integrated GPU.
#define ARM_BLOCKER_SAMPLES 8
#define ARM_FILTER_SAMPLES 12

// u_armShadowMap is the atlas's depth buffer (RasterShadows draws depth only), holding
// each view's linear depth 0..1: an orthographic tile matrix gives it as is, perspective
// views write it per pixel (vpraster_shadow_perspective.frag.glsl). Converting perspective
// depth here instead cost 0.7 ms on Larimar (AMD integrated GPU), sun views included.
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

// Points on a unit disc (Vogel spiral): point i of n at radius sqrt((i + 0.5) / n),
// angle i times the golden angle (2.39996323 rad), plus a turn per pixel. The loops
// step the direction by ARM_GOLDEN_TURN (its cosine and sine) instead of calling
// cos/sin per point; a constant table of the points would do too, but Chrome's
// Direct3D shader compiler (ANGLE, fxc) then takes ~30 s on the lighting pass.
const vec2 ARM_GOLDEN_TURN = vec2(-0.73736888, 0.67549029);

// `p` turned by the angle whose cosine and sine are `cs`
vec2 arm_rotate(vec2 p, vec2 cs)
{
    return vec2(p.x * cs.x - p.y * cs.y, p.x * cs.y + p.y * cs.x);
}

// Receiver depth at tile coordinates `uv` in a perspective view, exact: where the ray
// from the light through `uv` meets the receiver's plane (normal N). The view's frame:
// `axis` along it, `right` and `up` across, `k` = tile uv per unit of tan(angle).
// `planeDistance` is the receiver's distance along the axis times dot(N, its ray).
float arm_plane_depth(vec2 uv, vec3 axis, vec3 right, vec3 up, float k, vec3 N, float planeDistance,
                      float nearDistance, float depthRange, float fallback)
{
    vec3 d = axis + ((uv.x - 0.5) / k) * right - ((uv.y - 0.5) / k) * up;
    float nd = dot(N, d);
    if (abs(nd) < 1e-5 || planeDistance / nd <= 0.0) return fallback;
    return (planeDistance / nd - nearDistance) / depthRange;
}

// Visibility of `position` in one shadow view; `inside` is false outside its tile.
// Soft shadows follow PCSS (Fernando, NVIDIA 2005): the blockers' average depth
// gives the penumbra, filtered with a disc (measured on Eevee: disc-shaped edges).
//   sun (`size` = half angle): radius d tan(size) * u_armShadowInfo.y for a blocker
//     d metres away
//   local light (`size` = radius in metres): radius size (dr - db) / db *
//     u_armShadowInfo.w for receiver and blocker distances dr, db
// geomNormal: the triangle's own normal, for the normal offset (the shadow map
// holds the flat triangles, not the smooth shading normal), on the light's side.
// What every view of a light shares comes from arm_shadow(), worked out once:
// offsetScale (the normal offset, by the light's slope) and sunSpread (tan of the
// sun's half angle).
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
    // Only sun views (lighting.py: the lighting pass while no spot, point or area light
    // casts a shadow): the perspective code compiles out. Its mere presence slowed the
    // whole lighting pass (Larimar on an AMD integrated GPU: 1.5 ms)
    const bool perspective = false;
#else
    bool perspective = extra.w > 0.5;
#endif
    float tileTexels = tile.z / u_armShadowInfo.x;

    // One shadow texel in metres at the shaded point; offset along the normal,
    // more at grazing light
#ifdef ARM_SUN_SHADOWS_ONLY
    // Orthographic views: w is 1 (row 3 is 0, 0, 0, 1)
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

    // Receiver distance from the light (local) or from the depth range start (sun)
    float receiver = uvw.z * depthRange + nearDistance;
    float softUV = perspective
        ? size / max(0.25 * receiver, nearDistance) * uvPerMetreAtW1 // light disc seen through the receiver
        : sunSpread * u_armShadowInfo.y * receiver * uvPerMetre;

    // A tile is a column (sun) or a frustum (local light): also inside its depth range.
    // With `strict` (a sun cascade with a coarser one behind it) the whole soft shadow
    // kernel must fit in the tile, else samples clamped at its edge draw false shadows.
    float margin = 1.0 / tileTexels + (strict ? min(softUV, 0.1) : 0.0);
    inside = all(greaterThan(uvw.xy, vec2(margin))) && all(lessThan(uvw.xy, vec2(1.0 - margin))) && uvw.z < 1.0;
    if (!inside) return 1.0;
    margin = 1.0 / tileTexels;
    float depth = uvw.z - texelWorld / depthRange * 0.5;
    if (softUV > 1.5 / tileTexels)
    {
        // Rotation and radial shift per pixel and frame (interleaved gradient noise): over
        // TAA's frames the few reads cover the whole disc. (Stepping every pixel by the
        // same R2 offset per frame instead made the remaining noise move as a whole:
        // more flicker, not less.)
        float angle = 2.0 * M_PI * arm_ign(gl_FragCoord.xy, u_armShadowInfo.z);
        vec2 turn = vec2(cos(angle), sin(angle));
        float shift = arm_ign(gl_FragCoord.xy + vec2(47.0, 17.0), u_armShadowInfo.z);
        // Receiver plane depth bias (Isidoro, GDC 2006): compare against the receiver's
        // own depth at each tile offset, from its geometric normal, so sloped receivers
        // do not shadow themselves inside the kernel. Orthographic views: a linear
        // slope; perspective views: the exact ray-plane depth (arm_plane_depth).
        vec2 depthSlope = vec2(0.0); // depth units per tile uv (orthographic)
        vec3 axis = vec3(0.0), right = vec3(0.0), up = vec3(0.0); // perspective frame
        float planeDistance = 0.0;
        if (perspective)
        {
            // The view's axis is row W; right and up come from rows U and V, which are
            // axis / 2 + k * right and axis / 2 - k * up
            axis = rowW.xyz;
            right = (rowU.xyz - 0.5 * axis) / uvPerMetreAtW1;
            up = (0.5 * axis - rowV.xyz) / uvPerMetreAtW1;
            vec3 ray = axis + ((uvw.x - 0.5) / uvPerMetreAtW1) * right - ((uvw.y - 0.5) / uvPerMetreAtW1) * up;
            planeDistance = w * dot(geomNormal, ray);
        }
        else
        {
            // The normal in tile uv (per metre) and along the depth axis
            vec2 nUV = vec2(dot(geomNormal, rowU.xyz), dot(geomNormal, rowV.xyz)) / uvPerMetre;
            float nz = dot(geomNormal, normalize(rowDepth.xyz));
            nz = nz < 0.0 ? min(nz, -0.05) : max(nz, 0.05);
            depthSlope = -nUV / (nz * uvPerMetre * depthRange);
        }
        float planeBias = 2.0 / tileTexels * length(depthSlope) + texelWorld / depthRange;

        // 1. Blockers within the widest possible penumbra
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

        // 2. Penumbra from the blockers' average distance, 3. disc filter
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

    // Hard shadow: bilinear-weighted 2x2 comparison
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

// Visibility of `position` from the light: suns pick the finest cascade containing
// it (one view with an orthographic camera), point and area lights the cube face,
// spot lights have one view.
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
    // Only drawn with local shadows for the frames the pass that has them takes to
    // load (RenderPathViewportRaster): unshadowed meanwhile
    if (light.kind != ARM_LIGHT_SUN) return 1.0;
#endif
    int first = int(light.firstShadowView);
    int count = int(light.shadowViewCount);
    float size = light.kind == ARM_LIGHT_AREA ? 0.5 * max(light.areaWidth, light.areaHeight) : light.radius;
    // The triangle's side facing the light: the normal offset must move the point
    // towards the light. A two-sided surface lit on its back (its normal facing away)
    // casts on itself, and an offset into it shadowed whole texel rows in some frames.
    vec3 facing = dot(geomNormal, toLight) < 0.0 ? -geomNormal : geomNormal;
    float nl = clamp(dot(facing, toLight), 0.0, 1.0);
    float offsetScale = 0.25 + 0.75 * sqrt(1.0 - nl * nl);
    // Sun: tan of the half angle, kept below 90 degrees (as arm_lamp_cone): past it the
    // tangent turns negative and the soft shadow would become hard
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

// Universal Blender light. kind: 0 = sun, 1 = point, 2 = spot, 3 = area.
//   sun:   strength is irradiance in W/m2; direction is where the light travels.
//   point: power in W, radiant intensity P / (4 pi), inverse-square falloff.
//   spot:  a point light masked by a cone; spot_size is the full cone angle,
//          spot_blend softens the edge inwards.
//   area:  power in W from a one-sided flat (Lambertian) emitter facing
//          `direction`: radiant intensity P cos(theta) / pi (diffuse treats it
//          as small; highlights use its outline).
// Point, spot and area lights fade out towards `cutoff` (influence radius in
// metres from Eevee's light_threshold or the light's custom distance, 0 = none)
// with the window (1 - (d / cutoff)^4)^2, as measured on Eevee.
// Shadows: arm_shadow() (above) for lights with a shadow view.
// Highlights: the lamp's outline as seen from `position` goes to lamp.verts
// (vpraster_specular.glsl); lamps smaller than the measured table's sun
// (0.29 degree angular radius) are points. With ARM_POINT_LAMPS every lamp is a
// point (vpraster_specular.glsl).

// Polygons of ARM_LAMP_VERTS sides stand in for circles and ellipses. This scales the
// polygon's radius so that its area equals the circle's: sqrt(pi / (n/2 sin(2 pi / n)))
const float ARM_EQUAL_AREA = sqrt(M_PI / (0.5 * float(ARM_LAMP_VERTS) * sin(2.0 * M_PI / float(ARM_LAMP_VERTS))));

// Cone of half angle `a` around `axis` as a polygon of unit directions
void arm_lamp_cone(inout ArmLamp lamp, vec3 axis, float a)
{
#ifdef ARM_POINT_LAMPS
    // No lamp needs an outline (RasterLights.outlines). Every field set: Direct3D's
    // compiler rejects a lamp passed out partly unset
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

// Rectangle or ellipse of an area light as directions from `position`
void arm_lamp_area(inout ArmLamp lamp, LightData light, vec3 position)
{
    lamp.coneSinSq = 0.0;
#ifdef ARM_POINT_LAMPS
    // Only drawn with area lights for the frames the full lighting pass takes to load
    // (RenderPathViewportRaster): the light as a point, its solid angle the area seen
    // from `position` (the intensity in arm_light() multiplies by it)
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

// How much of a point, spot or area light reaches `position` before shadowing: the
// influence window, the spot cone, the area light's front side. `direction`: unit
// vector from `position` to the light, `distanceSq` the squared distance. Also used
// by the shadow pass, to skip the same points (vpraster_shadow_pass.glsl).
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

    // Where nothing reaches, the lamp's outline and shadow are skipped (the result is
    // the same: no light)
    float reach = arm_light_reach(light, position, lamp.direction, distanceSq);
    if (reach <= 0.0)
    {
        // Also keeps the outline away from points on an area light's own plane, where
        // it is degenerate (a NaN solid angle times no reach is still NaN)
        lamp.intensity = vec3(0.0);
        lamp.count = 0;
        return;
    }

    if (light.kind == ARM_LIGHT_AREA)
        arm_lamp_area(lamp, light, position);
    else
        // Measured on Eevee: a point/spot lamp is a disc of its radius facing the shaded
        // point (irradiance P / (4 pi (d^2 + r^2))), not a sphere
        arm_lamp_cone(lamp, lamp.direction, atan(light.radius * inversesqrt(distanceSq)));
    float shadow = reach * arm_shadow(light, position, geomNormal, lamp.direction);

    // Lamps with an outline: radiance times the outline's solid angle, so the averages
    // over the outline (arm_lamp_cosine, arm_lamp_lobe) give the exact integral.
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
