// Lights and shadows of the Eevee renderer's lighting pass (lighting.py puts
// eevee_specular.glsl before this file). Sizes are #defines from lighting.py.

struct LightData
{
    int kind;
    vec3 position;
    vec3 direction;
    vec3 color;
    float energy;
    float spot_size;
    float spot_blend;
    float cutoff;
    float shadow;
    float radius;
    float size_x;
    float size_y;
    float shape;
    vec3 tangent;
};

struct lightshader
{
    vec3 intensity;
    vec3 direction;
};

uniform vec4 u_lightPacked[MAX_LIGHT_SOURCES * ARM_LIGHT_VEC4S];

// Light layout, ARM_LIGHT_VEC4S vec4 per light (filled by armory.renderpath.eevee.EeveeLights):
//   0: kind, spot_size, spot_blend, unused
//   1: position.xyz, energy
//   2: direction.xyz, cutoff
//   3: color.rgb, first shadow view (-1 = none)
//   4: radius (sun: half angle, point/spot: metres), size_x, size_y, shape (area)
//   5: tangent.xyz (area: local X axis), unused
LightData arm_get_light(int index)
{
    vec4 a = u_lightPacked[index * ARM_LIGHT_VEC4S + 0];
    vec4 b = u_lightPacked[index * ARM_LIGHT_VEC4S + 1];
    vec4 c = u_lightPacked[index * ARM_LIGHT_VEC4S + 2];
    vec4 d = u_lightPacked[index * ARM_LIGHT_VEC4S + 3];
    LightData light;
    light.kind = int(a.x);
    light.spot_size = a.y;
    light.spot_blend = a.z;
    light.position = b.xyz;
    light.energy = b.w;
    light.direction = c.xyz;
    light.cutoff = c.w;
    light.color = d.xyz;
    light.shadow = d.w;
    vec4 e = u_lightPacked[index * ARM_LIGHT_VEC4S + 4];
    vec4 f = u_lightPacked[index * ARM_LIGHT_VEC4S + 5];
    light.radius = e.x;
    light.size_x = e.y;
    light.size_y = e.z;
    light.shape = e.w;
    light.tangent = f.xyz;
    return light;
}

// Shadow lookup

// Shadow views, ARM_SHADOW_VIEW_VEC4S vec4 each (filled by armory.renderpath.eevee.EeveeShadows):
//   0, 1: u and v numerators (tile 0..1, v down), 2: linear depth (0..1),
//   3: the divisor w (sun: 1), 4: the tile in the atlas (x, y, width, height),
//   5: tile uv per metre at w = 1, near distance (m), depth range (m), perspective
uniform vec4 u_armShadows[ARM_MAX_SHADOW_VIEWS * ARM_SHADOW_VIEW_VEC4S];
// x = 1 / atlas size in texels, y = sun soft shadow width relative to the physical
// penumbra and w = the same for local lights (Eevee's shadow_step_count, measured),
// z = frame index for the noise
uniform vec4 u_armShadowInfo;
uniform sampler2D u_armShadowMap;
// Geometric (triangle) normal of the shaded point (set at the start of main), for the
// normal offset: the shadow map holds the flat triangles
vec3 arm_geomNormal;

#define ARM_BLOCKER_SAMPLES 16
#define ARM_FILTER_SAMPLES 24

float arm_shadow_depth(vec2 texel)
{
    return textureLod(u_armShadowMap, (texel + 0.5) * u_armShadowInfo.x, 0.0).r;
}

// Depth at tile coordinates `uv`, kept inside the tile
float arm_shadow_depth_uv(vec4 rect, vec2 uv, float margin)
{
    uv = clamp(uv, vec2(margin), vec2(1.0 - margin));
    return textureLod(u_armShadowMap, rect.xy + uv * rect.zw, 0.0).r;
}

// Point i of n on a unit disc (Vogel spiral), turned by `angle`
vec2 arm_vogel(int i, int n, float angle)
{
    float r = sqrt((float(i) + 0.5) / float(n));
    float theta = float(i) * 2.39996323 + angle;
    return r * vec2(cos(theta), sin(theta));
}

// Receiver depth at tile coordinates `uv` in a perspective view, exact: the ray
// from the light through `uv` meets the receiver's plane (normal N). `wnd` is the
// receiver's distance along the view axis times N . its ray direction.
float arm_plane_depth(vec2 uv, vec3 f, vec3 right, vec3 up, float k, vec3 N, float wnd, vec4 extra, float fallback)
{
    vec3 d = f + ((uv.x - 0.5) / k) * right - ((uv.y - 0.5) / k) * up;
    float nd = dot(N, d);
    if (abs(nd) < 1e-5 || wnd / nd <= 0.0) return fallback;
    return (wnd / nd - extra.y) / extra.z;
}

// Visibility of `position` in one shadow view; `inside` is false outside its tile.
// Soft shadows follow PCSS (Fernando, NVIDIA 2005): the blockers' average depth
// gives the penumbra, filtered with a disc (measured on Eevee: disc-shaped edges).
//   sun (`size` = half angle): radius d tan(size) * u_armShadowInfo.y for a blocker
//     d metres away
//   local light (`size` = radius in metres): radius size (dr - db) / db *
//     u_armShadowInfo.w for receiver and blocker distances dr, db
float arm_shadow_view(int view, vec3 position, vec3 toLight, float size, bool strict, out bool inside)
{
    int o = view * ARM_SHADOW_VIEW_VEC4S;
    vec4 r0 = u_armShadows[o + 0];
    vec4 r1 = u_armShadows[o + 1];
    vec4 r2 = u_armShadows[o + 2];
    vec4 r3 = u_armShadows[o + 3];
    vec4 rect = u_armShadows[o + 4];
    vec4 extra = u_armShadows[o + 5];
    bool perspective = extra.w > 0.5;
    float tileTexels = rect.z / u_armShadowInfo.x;
    float depthRange = extra.z; // metres per depth unit

    // One shadow texel in metres at the shaded point; offset along the normal,
    // more at grazing light
    float w0 = dot(r3.xyz, position) + r3.w;
    inside = w0 > extra.y;
    if (!inside) return 1.0;
    float uvPerMetre = extra.x / w0;
    float texelWorld = 1.0 / (uvPerMetre * tileTexels);
    float nl = clamp(dot(arm_geomNormal, toLight), 0.0, 1.0);
    vec3 p = position + arm_geomNormal * texelWorld * (0.25 + 0.75 * sqrt(1.0 - nl * nl));
    float w = dot(r3.xyz, p) + r3.w;
    vec3 uvw = vec3((dot(r0.xyz, p) + r0.w) / w, (dot(r1.xyz, p) + r1.w) / w, dot(r2.xyz, p) + r2.w);

    // Receiver distance from the light (local) or from the depth range start (sun)
    float receiver = uvw.z * depthRange + extra.y;
    float softUV = perspective
        ? size / max(0.25 * receiver, extra.y) * extra.x // light disc seen through the receiver
        : tan(size) * u_armShadowInfo.y * receiver * uvPerMetre;

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
        // Rotation per pixel and frame (interleaved gradient noise); TAA averages it
        vec2 pixel = gl_FragCoord.xy + u_armShadowInfo.z * 5.588238;
        float angle = 6.28318531 * fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
        // Receiver plane depth bias (Isidoro, GDC 2006): compare against the receiver's
        // own depth at each tile offset, from its geometric normal, so sloped receivers
        // do not shadow themselves inside the kernel. Orthographic views: a linear
        // slope; perspective views: the exact ray-plane depth (arm_plane_depth).
        vec3 axisD = normalize(r2.xyz);
        vec3 nLight = vec3(dot(arm_geomNormal, r0.xyz), dot(arm_geomNormal, r1.xyz), dot(arm_geomNormal, axisD) * uvPerMetre) / uvPerMetre;
        float nz = nLight.z < 0.0 ? min(nLight.z, -0.05) : max(nLight.z, 0.05);
        vec2 depthSlope = perspective ? vec2(0.0) : -nLight.xy / (nz * uvPerMetre * depthRange); // depth units per tile uv
        // Perspective frame: f along the view, right/up from the u/v rows (r0 = f/2 + k right)
        vec3 f = r3.xyz;
        vec3 right = (r0.xyz - 0.5 * f) / extra.x;
        vec3 up = (0.5 * f - r1.xyz) / extra.x;
        vec3 dirP = f + ((uvw.x - 0.5) / extra.x) * right - ((uvw.y - 0.5) / extra.x) * up;
        float wnd = w * dot(arm_geomNormal, dirP);
        float planeBias = 2.0 / tileTexels * length(depthSlope) + texelWorld / depthRange;

        // 1. Blockers within the widest possible penumbra
        float search = min(softUV, 0.1);
        float blockerSum = 0.0;
        float blockers = 0.0;
        for (int i = 0; i < ARM_BLOCKER_SAMPLES; i++)
        {
            vec2 offset = arm_vogel(i, ARM_BLOCKER_SAMPLES, angle) * search;
            float d = arm_shadow_depth_uv(rect, uvw.xy + offset, margin);
            float expected = perspective ? arm_plane_depth(uvw.xy + offset, f, right, up, extra.x, arm_geomNormal, wnd, extra, depth) : depth + dot(depthSlope, offset);
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
            float blocker = max(blockerDepth * depthRange + extra.y, 1e-4);
            radius = size * (receiver - blocker) / blocker * u_armShadowInfo.w * uvPerMetre;
        }
        else
        {
            radius = tan(size) * u_armShadowInfo.y * (depth - blockerDepth) * depthRange * uvPerMetre;
        }
        radius = max(radius, 1.0 / tileTexels);
        float lit = 0.0;
        for (int i = 0; i < ARM_FILTER_SAMPLES; i++)
        {
            vec2 offset = arm_vogel(i, ARM_FILTER_SAMPLES, angle) * radius;
            float d = arm_shadow_depth_uv(rect, uvw.xy + offset, margin);
            float expected = perspective ? arm_plane_depth(uvw.xy + offset, f, right, up, extra.x, arm_geomNormal, wnd, extra, depth) : depth + dot(depthSlope, offset);
            lit += expected - planeBias <= d ? 1.0 : 0.0;
        }
        return lit / float(ARM_FILTER_SAMPLES);
    }

    // Hard shadow: bilinear-weighted 2x2 comparison
    vec2 texel = (rect.xy + uvw.xy * rect.zw) / u_armShadowInfo.x - 0.5;
    vec2 base = floor(texel);
    vec2 f = texel - base;
    vec4 lit = vec4(
        depth <= arm_shadow_depth(base) ? 1.0 : 0.0,
        depth <= arm_shadow_depth(base + vec2(1.0, 0.0)) ? 1.0 : 0.0,
        depth <= arm_shadow_depth(base + vec2(0.0, 1.0)) ? 1.0 : 0.0,
        depth <= arm_shadow_depth(base + vec2(1.0, 1.0)) ? 1.0 : 0.0);
    return mix(mix(lit.x, lit.y, f.x), mix(lit.z, lit.w, f.x), f.y);
}

// Visibility of `position` from the light: suns pick the finest cascade containing
// it, point and area lights the cube face, spot lights have one view.
float arm_shadow(LightData light, vec3 position, vec3 toLight)
{
    if (light.shadow < 0.0) return 1.0;
    int first = int(light.shadow);
    int count = light.kind == 0 ? ARM_SUN_CASCADES : (light.kind == 2 ? 1 : 6);
    float size = light.kind == 3 ? 0.5 * max(light.size_x, light.size_y) : light.radius;
    for (int i = 0; i < 6; i++)
    {
        if (i >= count) break;
        bool inside;
        float visibility = arm_shadow_view(first + i, position, toLight, size, light.kind == 0 && i < count - 1, inside);
        if (inside) return visibility;
    }
    return 1.0;
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
// Highlights: the lamp's outline as seen from `position` goes to arm_lampVerts
// (eevee_specular.glsl); lamps smaller than the measured table's sun
// (0.29 degree angular radius) are points.

// Polygons stand in for circles and ellipses with the same area: an octagon's
// radius scaled by sqrt(pi / (4 sin(pi / 4)))
const float ARM_EQUAL_AREA = 1.0539;

// Cone of half angle `a` around `axis` as a polygon of unit directions
void arm_lamp_cone(vec3 axis, float a)
{
    if (a < 0.005)
    {
        arm_lampCount = 0;
        return;
    }
    vec3 helper = abs(axis.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 x = normalize(cross(helper, axis));
    vec3 y = cross(axis, x);
    float t = tan(min(a, 1.5)) * ARM_EQUAL_AREA;
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        float phi = float(i) * (6.28318531 / float(ARM_LAMP_VERTS));
        arm_lampVerts[i] = normalize(axis + t * (cos(phi) * x + sin(phi) * y));
    }
    arm_lampCount = ARM_LAMP_VERTS;
    arm_lampSolidAngle = 6.28318531 * (1.0 - cos(a));
    arm_lampConeAxis = axis;
    arm_lampConeSinSq = sin(a) * sin(a);
}

// Rectangle or ellipse of an area light as directions from `position`
void arm_lamp_area(LightData light, vec3 position)
{
    arm_lampConeSinSq = 0.0;
    vec3 x = light.tangent * (0.5 * light.size_x);
    vec3 y = cross(light.direction, light.tangent) * (0.5 * light.size_y);
    if (light.shape < 0.5)
    {
        arm_lampVerts[0] = normalize(light.position - x - y - position);
        arm_lampVerts[1] = normalize(light.position + x - y - position);
        arm_lampVerts[2] = normalize(light.position + x + y - position);
        arm_lampVerts[3] = normalize(light.position - x + y - position);
        arm_lampCount = 4;
        arm_lampSolidAngle = arm_polygon_solid_angle(4);
        return;
    }
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        float phi = float(i) * (6.28318531 / float(ARM_LAMP_VERTS));
        arm_lampVerts[i] = normalize(light.position + ARM_EQUAL_AREA * (cos(phi) * x + sin(phi) * y) - position);
    }
    arm_lampCount = ARM_LAMP_VERTS;
    arm_lampSolidAngle = arm_polygon_solid_angle(ARM_LAMP_VERTS);
}

void arm_light(LightData light, vec3 position, out lightshader result)
{
    if (light.kind == 0)
    {
        result.direction = -light.direction;
        result.intensity = light.color * (light.energy * arm_shadow(light, position, result.direction));
        arm_lamp_cone(result.direction, light.radius);
        return;
    }

    vec3 toLight = light.position - position;
    float distanceSq = max(dot(toLight, toLight), 1e-8);
    result.direction = toLight * inversesqrt(distanceSq);
    if (light.kind == 3)
        arm_lamp_area(light, position);
    else
        // Measured on Eevee: a point/spot lamp is a disc of its radius facing the shaded
        // point (irradiance P / (4 pi (d^2 + r^2))), not a sphere
        arm_lamp_cone(result.direction, atan(light.radius * inversesqrt(distanceSq)));

    float window = 1.0;
    if (light.cutoff > 0.0)
    {
        float x = distanceSq / (light.cutoff * light.cutoff);
        window = clamp(1.0 - x * x, 0.0, 1.0);
        window *= window;
    }

    // Lamps with an outline: radiance times the outline's solid angle, so the averages
    // over the outline (arm_lamp_cosine, arm_lamp_lobe) give the exact integral.
    if (light.kind == 3)
    {
        // One-sided Lambertian emitter: radiance P / (pi area)
        float area = light.shape < 0.5 ? light.size_x * light.size_y : 0.25 * M_PI * light.size_x * light.size_y;
        bool front = dot(position - light.position, light.direction) > 0.0;
        float radiance = front ? light.energy / (M_PI * max(area, 1e-8)) : 0.0;
        result.intensity = light.color * (radiance * arm_lampSolidAngle * window
            * arm_shadow(light, position, result.direction));
        return;
    }

    float shadow = arm_shadow(light, position, result.direction);
    if (arm_lampCount > 0)
    {
        // Disc of radius r with the sphere light's radiance P / (4 pi^2 r^2)
        float radiance = light.energy / (4.0 * M_PI * M_PI * light.radius * light.radius);
        result.intensity = light.color * (radiance * arm_lampSolidAngle * window * shadow);
    }
    else
    {
        result.intensity = light.color * (light.energy * window * shadow / (4.0 * M_PI * distanceSq));
    }

    if (light.kind == 2)
    {
        float cosAngle = dot(-result.direction, light.direction);
        float cosEdge = cos(light.spot_size * 0.5);
        float blendWidth = max((1.0 - cosEdge) * light.spot_blend, 1e-6);
        result.intensity *= smoothstep(0.0, 1.0, (cosAngle - cosEdge) / blendWidth);
    }
}
