"""Text fixes applied to MaterialX's generated GLSL before Krafix sees it.

flatten_varyings: MaterialX passes vertex data in an interface block
    (`in VertexData { ... } vd;`). Krafix turns the vertex-stage block into a
    separate output parameter, which puts SV_Position first in the D3D11
    output signature while the pixel stage expects the block members first.
    D3D11 links stages by register, so every varying arrived shifted by one
    (the tangent received the normal). Plain varyings keep both stages in the
    same order.

pack_lights: MaterialX declares the lights as an array of structs. Struct
    arrays pack differently on D3D11 and OpenGL and OpenGL needs one location
    per member, so the lights become one plain vec4 array with a fixed layout
    (LIGHT_VEC4S per light, see unpack below) that Haxe fills the same way on
    every backend.

light_scales: Eevee's direct/indirect light intensity and clamp settings.

gbuffer_output: the material pass writes the material images, not a colour.
"""
import re

LIGHT_VEC4S = 6
MAX_SHADOW_VIEWS = 32  # EeveeShadows.MAX_VIEWS
SHADOW_VIEW_VEC4S = 6  # EeveeShadows.VIEW_VEC4S
SUN_CASCADES = 4  # EeveeShadows.SUN_CASCADES

# The LightData struct MaterialX builds from Shaders/eevee/materialx/arm_lights.mtlx
LIGHT_MEMBERS = [
    ('int', 'type'), ('int', 'kind'), ('vec3', 'position'), ('vec3', 'direction'),
    ('vec3', 'color'), ('float', 'energy'), ('float', 'spot_size'), ('float', 'spot_blend'),
    ('float', 'cutoff'), ('float', 'shadow'), ('float', 'radius'), ('float', 'size_x'),
    ('float', 'size_y'), ('float', 'shape'), ('vec3', 'tangent'),
]

# Shadow lookup, declared with the lights so arm_light.glsl can call arm_shadow().
SHADOWS = """
#define ARM_MAX_SHADOW_VIEWS %(views)d
#define ARM_SHADOW_VIEW_VEC4S %(vec4s)d
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
    int count = light.kind == 0 ? %(cascades)d : (light.kind == 2 ? 1 : 6);
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
""" % {'views': MAX_SHADOW_VIEWS, 'cascades': SUN_CASCADES, 'vec4s': SHADOW_VIEW_VEC4S}

LIGHT_UNPACK = """
uniform vec4 u_lightPacked[MAX_LIGHT_SOURCES * %(n)d];

// Light layout, %(n)d vec4 per light (filled by armory.renderpath.eevee.EeveeLights):
//   0: type, kind, spot_size, spot_blend
//   1: position.xyz, energy
//   2: direction.xyz, cutoff
//   3: color.rgb, first shadow view (-1 = none)
//   4: radius (sun: half angle, point/spot: metres), size_x, size_y, shape (area)
//   5: tangent.xyz (area: local X axis), unused
LightData arm_get_light(int index)
{
    vec4 a = u_lightPacked[index * %(n)d + 0];
    vec4 b = u_lightPacked[index * %(n)d + 1];
    vec4 c = u_lightPacked[index * %(n)d + 2];
    vec4 d = u_lightPacked[index * %(n)d + 3];
    LightData light;
    light.type = int(a.x);
    light.kind = int(a.y);
    light.spot_size = a.z;
    light.spot_blend = a.w;
    light.position = b.xyz;
    light.energy = b.w;
    light.direction = c.xyz;
    light.cutoff = c.w;
    light.color = d.xyz;
    light.shadow = d.w;
    vec4 e = u_lightPacked[index * %(n)d + 4];
    vec4 f = u_lightPacked[index * %(n)d + 5];
    light.radius = e.x;
    light.size_x = e.y;
    light.size_y = e.z;
    light.shape = e.w;
    light.tangent = f.xyz;
    return light;
}
""" % {'n': LIGHT_VEC4S} + SHADOWS

LIGHT_SCALES = """
// Eevee's light intensity and clamping (scene.eevee), set by the engine:
// x = intensity, y = clamp (0 = off). Measured Eevee behaviour: the clamp scales
// the colour down by its brightest channel (keeps the hue) and the intensity
// applies after it. Direct: the summed reflected light of all lights. Indirect:
// the incoming world light, before the BSDF.
uniform vec2 u_armDirect;
uniform vec2 u_armIndirect;

vec3 arm_clamp_scale(vec3 color, vec2 settings)
{
    float peak = max(color.r, max(color.g, color.b));
    if (settings.y > 0.0 && peak > settings.y) color *= settings.y / peak;
    return color * settings.x;
}

"""

# (pattern, replacement) pairs applied by light_scales(); each must match at least once
LIGHT_SCALE_EDITS = [
    # Direct: sum the lights, then clamp and scale the sum once after the loop
    (r'(\n(\s*)int numLights = numActiveLightSources\(\);)',
     r'\n\2vec3 armDirect = vec3(0.0);\1'),
    (r'shader_constructor_out\.color \+= (lightShader\.intensity \* \w+\.response);',
     r'armDirect += \1;'),
    (r'(\n(\s*)// Ambient occlusion)',
     r'\n\2shader_constructor_out.color += arm_clamp_scale(armDirect, u_armDirect);\1'),
    # Indirect: clamp and scale the incoming world light of every lookup
    (r'(vec3 Li = mx_latlong_map_lookup\([^;]*\);)',
     r'\1\n    Li = arm_clamp_scale(Li, u_armIndirect);'),
]


def flatten_varyings(src: str) -> str:
    block = re.compile(r'\b(in|out)\s+VertexData\s*\{([^}]*)\}\s*vd\s*;', re.S)
    match = block.search(src)
    if match is None:
        return src
    qualifier, members = match.group(1), match.group(2)
    lines = []
    for decl in members.split(';'):
        decl = decl.strip()
        if decl:
            kind, name = decl.split()
            lines.append('%s %s vd_%s;' % (qualifier, kind, name))
    src = src[:match.start()] + '\n'.join(lines) + src[match.end():]
    return re.sub(r'\bvd\.([A-Za-z_][A-Za-z0-9_]*)', r'vd_\1', src)


def pack_lights(src: str) -> str:
    struct = re.search(r'struct LightData\s*\{([^}]*)\};', src)
    if struct is None:
        return src
    members = [tuple(m.split()) for m in (s.strip() for s in struct.group(1).split(';')) if m]
    if members != LIGHT_MEMBERS:
        raise RuntimeError('Unexpected MaterialX LightData layout: %s' % members)
    declaration = re.compile(r'uniform LightData u_lightData\[MAX_LIGHT_SOURCES\];')
    if not declaration.search(src):
        raise RuntimeError('MaterialX light uniform not found')
    src = declaration.sub(lambda _: LIGHT_UNPACK, src)
    return re.sub(r'\bu_lightData\[([^\]]+)\]', r'arm_get_light(\1)', src)


def light_scales(src: str) -> str:
    """Applies Eevee's direct/indirect intensity and clamp settings to MaterialX's surface."""
    first_function = re.search(r'^\w[\w ]*\s+\w+\s*\([^;{]*\)\s*\{', src, re.M)
    if first_function is None:
        raise RuntimeError('No function found in the MaterialX shader')
    src = src[:first_function.start()] + LIGHT_SCALES + src[first_function.start():]
    for pattern, replacement in LIGHT_SCALE_EDITS:
        src, count = re.subn(pattern, replacement, src)
        if count == 0:
            raise RuntimeError('MaterialX surface code not found: %s' % pattern)
    return src


VIEW_DIRECTION = """
// Direction towards the viewer. MaterialX assumes a perspective camera; with an
// orthographic one every view ray is parallel. u_armViewDir: xyz = towards the
// camera, w = 1 for an orthographic camera (set by the engine).
uniform vec4 u_armViewDir;

vec3 arm_view_direction(vec3 position)
{
    return u_armViewDir.w > 0.5 ? u_armViewDir.xyz : normalize(u_viewPosition - position);
}

"""


def orthographic_view(src: str) -> str:
    """Makes MaterialX's view direction correct for orthographic cameras."""
    pattern = re.compile(r'normalize\(u_viewPosition - (\w+)\)')
    if not pattern.search(src):
        raise RuntimeError('MaterialX view direction not found')
    src = pattern.sub(r'arm_view_direction(\1)', src)
    first_function = re.search(r'^\w[\w ]*\s+\w+\s*\([^;{]*\)\s*\{', src, re.M)
    return src[:first_function.start()] + VIEW_DIRECTION + src[first_function.start():]


LIGHTING_INPUTS = """
// Lighting pass: the pixel's surface comes from the material images
// (Shaders/eevee/materialx/arm_gbuffer.glsl) and the depth buffer.
in vec2 texCoord;
uniform sampler2D gbuffer0;
uniform sampler2D gbuffer1;
uniform sampler2D gbuffer2;
uniform sampler2D gbuffer3;
uniform sampler2D gbuffer4;
uniform sampler2D gbufferDepth;
uniform mat4 invVP;

vec3 arm_decode_octahedral(vec2 e)
{
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

"""

# Varyings of the generated surface -> how the lighting pass gets them
LIGHTING_VARYINGS = {
    'vd_positionWorld': 'armWorld.xyz / armWorld.w',
    'vd_normalWorld': 'arm_decode_octahedral(armGbuffer1.xy)',
    # Only anisotropic specular reads it, which the material images do not hold
    'vd_tangentWorld': 'normalize(cross(abs(vd_normalWorld.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0), vd_normalWorld))',
}


def lighting_inputs(src: str, surface_inputs: set, reads: dict) -> str:
    """Lighting pass (RenderPathEevee): MaterialX's surface shader for one full-screen
    triangle. The surface inputs in `reads` come from the material images (GLSL
    expressions over armGbuffer0..4), every other surface input becomes a constant
    with its value; the varyings come from the images and the depth buffer."""
    def surface_uniform(match):
        kind, name, value = match.group(1), match.group(2), match.group(3)
        if name not in surface_inputs:
            return match.group(0)
        return '%s %s;' % (kind, name) if name in reads else 'const %s %s = %s;' % (kind, name, value)
    src = re.sub(r'^uniform (\w+) (\w+) = ([^;]+);', surface_uniform, src, flags=re.M)
    missing = [name for name in reads if not re.search(r'^\w+ %s;' % name, src, re.M)]
    if missing:
        raise RuntimeError('MaterialX surface inputs not found: %s' % missing)

    varyings = re.findall(r'^in \w+ (vd_\w+);', src, re.M)
    unknown = [name for name in varyings if name not in LIGHTING_VARYINGS]
    if unknown:
        raise RuntimeError('No lighting pass recipe for MaterialX varyings: %s' % unknown)
    src = re.sub(r'^in (\w+) (vd_\w+);', r'\1 \2;', src, flags=re.M)

    src = re.sub(r'^(#version \d+)\n', r'\1\n#include "compiled.inc"\n', src, count=1)
    first_function = re.search(r'^\w[\w ]*\s+\w+\s*\([^;{]*\)\s*\{', src, re.M)
    src = src[:first_function.start()] + LIGHTING_INPUTS + src[first_function.start():]

    setup = [
        'float armDepth = textureLod(gbufferDepth, texCoord, 0.0).r;',
        'if (armDepth == 1.0) discard; // sky: the world pass drew it',
    ]
    setup += ['vec4 armGbuffer%d = textureLod(gbuffer%d, texCoord, 0.0);' % (i, i) for i in range(5)]
    setup += [
        'vec2 armNdc = texCoord * 2.0 - 1.0;',
        '#ifdef _InvY',
        'armNdc.y = -armNdc.y;',
        '#endif',
        'vec4 armWorld = invVP * vec4(armNdc, armDepth * 2.0 - 1.0, 1.0);',
    ]
    setup += ['%s = %s;' % (name, LIGHTING_VARYINGS[name]) for name in LIGHTING_VARYINGS if name in varyings]
    setup += ['arm_geomNormal = arm_decode_octahedral(armGbuffer1.zw);']
    setup += ['%s = %s;' % (name, expression) for name, expression in reads.items()]
    main = re.compile(r'(\nvoid main\(\)\s*\{)')
    if not main.search(src):
        raise RuntimeError('MaterialX main() not found')
    code = ''.join('\n' + line if line.startswith('#') else '\n    ' + line for line in setup)
    return main.sub(lambda m: m.group(1) + code, src, count=1)


def gbuffer_output(src: str) -> str:
    """Material pass (arm_gbuffer): writes the material images instead of a colour.
    The last image also holds the pixel's screen motion for temporal anti-aliasing
    (current minus previous NDC position, from the unjittered clip positions the
    vertex stage passes in, vertex.py)."""
    output = re.compile(r'^out vec4 (\w+);', re.M)
    match = output.search(src)
    if match is None:
        raise RuntimeError('MaterialX pixel output not found')
    declarations = ('vec4 %s;\n' % match.group(1) +
                    ''.join('layout(location = %d) out vec4 armGbuffer%d;\n' % (i, i) for i in range(5)) +
                    'in vec4 vd_armClip;\n'
                    'in vec4 vd_armPrevClip;')
    src = src[:match.start()] + declarations + src[match.end():]
    end = src.rstrip().rfind('}')  # main() is the last function
    if not re.search(r'\nvoid main\(\)\s*\{', src) or end < 0:
        raise RuntimeError('MaterialX main() not found')
    write = ''.join('    armGbuffer%d = arm_gbuffer%d;\n' % (i, i) for i in range(4))
    write += ('    armGbuffer4 = vec4(vd_armClip.xy / vd_armClip.w - vd_armPrevClip.xy / vd_armPrevClip.w, '
              'arm_gbuffer4, 1.0);\n')
    return src[:end] + write + src[end:]


EEVEE_SPECULAR = """
// Eevee's specular reflectance, measured (Shaders/eevee/eevee_dfg.bin, see
// EeveeUniforms): a split-sum table, x = scale of F0, y = scale of F90, rows
// N.V = 1 - (i + 0.5) / 32 (row 0 = head-on), columns roughness j / 31.
uniform sampler2D u_armDfg;

vec2 arm_dfg(float NdotV, float alpha)
{
    float roughness = sqrt(clamp(alpha, 0.0, 1.0));
    vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, clamp(1.0 - NdotV, 0.5 / 32.0, 31.5 / 32.0));
    return textureLod(u_armDfg, uv, 0.0).xy;
}

// Lamp reflections, measured on Eevee (Shaders/eevee/eevee_ltc.bin): a Linearly
// Transformed Cosine lobe (Heitz et al. 2016) fitted to Eevee's lamp highlights.
// 32 x 64 texels, rows N.V = 1 - i / 31 (row 0 exactly head-on), columns
// roughness j / 31. Top half: inverse matrix [[x, 0, y], [0, z, 0], [w, 0, 1]] in a
// frame with x along the view direction projected on the surface and z along the
// normal; bottom half: the lobe's scale (x). Eevee does not clip the lobe at the
// surface horizon.
uniform sampler2D u_armLtc;

// The lamp being shaded as seen from the shaded point (set by arm_light): a
// polygon of unit directions (disc, sphere or area outline), or no vertices for
// a lamp too small to matter. Measured on Eevee: a lamp's highlight is its lobe
// averaged over the lamp's solid angle.
#define ARM_LAMP_VERTS 8
vec3 arm_lampVerts[ARM_LAMP_VERTS];
int arm_lampCount = 0;
// Solid angle of the lamp's outline: exact for cones (sun, point, spot); a polygon's
// triple products lose all float precision for small lamps
float arm_lampSolidAngle = 0.0;
// Circular lamps (sun, point, spot): the cone's axis and sin^2 of its half angle (0 = not a cone)
vec3 arm_lampConeAxis;
float arm_lampConeSinSq = 0.0;

// Integral of the clamped cosine / pi over the spherical polygon v0..v(n-1),
// clipped to z >= 0 (Heitz et al. 2016, edge integral in a stable form).
float arm_polygon_cosine(vec3 v[ARM_LAMP_VERTS + 1], int n)
{
    // Clip against z = 0 (Sutherland-Hodgman, one plane)
    vec3 c[ARM_LAMP_VERTS + 2];
    int m = 0;
    for (int i = 0; i < ARM_LAMP_VERTS + 1; i++)
    {
        if (i >= n) break;
        vec3 a = v[i];
        vec3 b = v[i + 1 < n ? i + 1 : 0];
        if (a.z >= 0.0) c[m++] = a;
        if ((a.z >= 0.0) != (b.z >= 0.0)) c[m++] = mix(a, b, a.z / (a.z - b.z));
    }
    float sum = 0.0;
    for (int i = 0; i < ARM_LAMP_VERTS + 2; i++)
    {
        if (i >= m) break;
        vec3 a = normalize(c[i]);
        vec3 b = normalize(c[i + 1 < m ? i + 1 : 0]);
        vec3 x = cross(a, b);
        float s = length(x);
        float angle = 2.0 * asin(clamp(0.5 * length(a - b), 0.0, 1.0)); // precise for small edges
        sum += s > 1e-12 ? x.z * angle / s : 0.0;
    }
    return abs(sum) / (2.0 * 3.14159265);
}

// Solid angle of the spherical polygon (fan of triangles, Van Oosterom and Strackee)
float arm_polygon_solid_angle(int n)
{
    float omega = 0.0;
    vec3 a = arm_lampVerts[0];
    for (int i = 1; i < ARM_LAMP_VERTS - 1; i++)
    {
        if (i + 1 >= n) break;
        vec3 b = arm_lampVerts[i];
        vec3 c = arm_lampVerts[i + 1];
        omega += 2.0 * atan(abs(dot(a, cross(b, c))), 1.0 + dot(a, b) + dot(b, c) + dot(c, a));
    }
    return omega;
}

// Diffuse from the lamp: the cosine averaged over the lamp's outline, clipped at the
// surface horizon (measured on Eevee: large lamps light diffuse surfaces by their
// visible shape), in place of N.L
float arm_lamp_cosine(vec3 N, float NdotL)
{
    if (arm_lampCount == 0) return NdotL;
    if (arm_lampConeSinSq > 0.0)
    {
        // Circular lamp: closed form of the cosine over a disc of angular radius a cut by
        // the horizon (Snyder 1996), free of the cancellation the polygon edges suffer
        // with small lamps near the horizon
        float cosTheta = clamp(dot(N, arm_lampConeAxis), -1.0, 1.0);
        float sinSq = arm_lampConeSinSq;
        float projected; // integral of the cosine over the visible disc
        if (cosTheta * cosTheta > sinSq)
            projected = 3.14159265 * sinSq * max(cosTheta, 0.0);
        else
        {
            float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 1e-8));
            float x = sqrt(max(1.0 / sinSq - 1.0, 1e-8));
            float y = clamp(-x * cosTheta / sinTheta, -1.0, 1.0);
            float s = sinTheta * sqrt(1.0 - y * y);
            projected = max((cosTheta * acos(y) - x * s) * sinSq + atan(s / x), 0.0);
        }
        // Over the same solid angle the lamp's intensity uses (radiance x solid angle),
        // so the product is radiance x the projected integral, exactly
        return projected / max(arm_lampSolidAngle, 1e-12);
    }
    vec3 T = abs(N.z) < 0.999 ? normalize(cross(N, vec3(0.0, 0.0, 1.0))) : vec3(1.0, 0.0, 0.0);
    vec3 B = cross(N, T);
    vec3 local[ARM_LAMP_VERTS + 1];
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        if (i >= arm_lampCount) break;
        vec3 d = arm_lampVerts[i];
        local[i] = vec3(dot(d, T), dot(d, B), dot(d, N));
    }
    float omega = max(arm_lampSolidAngle, 1e-12);
    return 3.14159265 * arm_polygon_cosine(local, arm_lampCount) / omega;
}

// f * cos towards the lamp for F = 1: the lobe at L for a small lamp, else the lobe
// averaged over the lamp's polygon
float arm_lamp_lobe(vec3 N, vec3 V, vec3 L, float NdotV, float alpha)
{
    float roughness = sqrt(clamp(alpha, 0.0, 1.0));
    float row = clamp(1.0 - NdotV, 0.0, 1.0) * 31.0 + 0.5;
    vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, row / 64.0);
    vec4 m = textureLod(u_armLtc, uv, 0.0);
    float scale = textureLod(u_armLtc, uv + vec2(0.0, 0.5), 0.0).x;
    vec3 T1 = V - N * dot(N, V);
    T1 = dot(T1, T1) > 1e-8 ? normalize(T1) : (abs(N.z) < 0.999 ? normalize(cross(N, vec3(0.0, 0.0, 1.0))) : vec3(1.0, 0.0, 0.0));
    vec3 T2 = cross(N, T1);
    if (arm_lampCount > 0)
    {
        vec3 transformed[ARM_LAMP_VERTS + 1];
        for (int i = 0; i < ARM_LAMP_VERTS; i++)
        {
            if (i >= arm_lampCount) break;
            vec3 d = arm_lampVerts[i];
            vec3 l = vec3(dot(d, T1), dot(d, T2), dot(d, N));
            transformed[i] = vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
        }
        float omega = max(arm_lampSolidAngle, 1e-12);
        return scale * arm_polygon_cosine(transformed, arm_lampCount) / omega;
    }
    vec3 l = vec3(dot(L, T1), dot(L, T2), dot(L, N));
    vec3 lo = vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
    float len2 = dot(lo, lo);
    float len = sqrt(len2);
    float det = m.z * (m.x - m.y * m.w);
    return scale * max(lo.z / len, 0.0) / 3.14159265 * abs(det) / (len2 * len);
}

"""

# (pattern, replacement) pairs applied by eevee_specular(); each must match exactly once
EEVEE_SPECULAR_EDITS = [
    # Directional albedo: F0 * A + F90 * B from the measured table
    (r'vec3 mx_ggx_dir_albedo\(float NdotV, float alpha, vec3 F0, vec3 F90\)\n\{.*?\n\}',
     'vec3 mx_ggx_dir_albedo(float NdotV, float alpha, vec3 F0, vec3 F90)\n{\n'
     '    vec2 ab = arm_dfg(NdotV, alpha);\n'
     '    return F0 * ab.x + F90 * ab.y;\n}'),
    # Multiple scattering: 1 / (1 - Favg (1 - Ess)), Favg = F0 + (1 - F0) / 21 (measured on
    # Eevee). The third argument is F0, not the Fresnel term (call sites below).
    (r'vec3 mx_ggx_energy_compensation\(float NdotV, float alpha, vec3 Fss\)\n\{.*?\n\}',
     'vec3 mx_ggx_energy_compensation(float NdotV, float alpha, vec3 F0)\n{\n'
     '    vec2 ab = arm_dfg(NdotV, alpha);\n'
     '    vec3 favg = F0 + (1.0 - F0) / 21.0;\n'
     '    return 1.0 / (1.0 - favg * (1.0 - ab.x - ab.y));\n}'),
    # Diffuse from lamps: the cosine over the lamp's outline (arm_lamp_cosine)
    (r'bsdf\.response = diffuse \* closureData\.occlusion \* weight \* NdotL \* M_PI_INV;',
     'bsdf.response = diffuse * closureData.occlusion * weight * arm_lamp_cosine(N, NdotL) * M_PI_INV;'),
    # World reflection: the table replaces MaterialX's F * G (applied at the call sites)
    (r'vec3 FG = fd\.refraction \? vec3\(1\.0\) - \(F \* G\) : F \* G;',
     'vec3 FG = fd.refraction ? vec3(1.0) - (F * G) : vec3(1.0);'),
]

# Per BSDF function: (function name, F0 expression, F90 expression, its world reflection
# line, its lamp reflection line, the lamp reflection's tint factor)
EEVEE_SPECULAR_BSDFS = [
    # Dielectric F90: measured on Eevee, grazing reflection fades out as Specular IOR
    # Level goes to 0 (none at 0, full from about 0.16, i.e. F0 = 0.0125)
    ('mx_dielectric_bsdf', 'vec3(F0)', 'vec3(min(1.0, F0 / 0.0125))', 'bsdf.response = Li * safeTint * comp * weight;',
     'bsdf.response = D * F * G * comp * safeTint * closureData.occlusion * weight / (4.0 * NdotV);', 'safeTint * '),
    ('mx_generalized_schlick_bsdf', 'safeColor0', 'safeColor90', 'bsdf.response = Li * comp * weight;',
     'bsdf.response = D * F * G * comp * closureData.occlusion * weight / (4.0 * NdotV);', ''),
]
# Lamp reflection: the measured lobe (white metal) times the surface's reflectance
# relative to white metal, which is Eevee's world reflectance (measured): directional
# albedo times the multiple-scattering term (`comp`, computed with F0 above)
LAMP_RESPONSE = ('bsdf.response = mx_ggx_dir_albedo(NdotV, avgAlpha, %s, %s) * comp * '
                 'arm_lamp_lobe(N, V, L, NdotV, avgAlpha) * %sclosureData.occlusion * weight;')


def eevee_specular(src: str) -> str:
    """Makes MaterialX's GGX reflectance match Eevee's Principled BSDF: the measured
    split-sum table for the directional albedo and Eevee's multiple-scattering term.
    The diffuse under a dielectric already uses 1 - reflectance (bsdf.throughput)."""
    first_function = re.search(r'^\w[\w ]*\s+\w+\s*\([^;{]*\)\s*\{', src, re.M)
    src = src[:first_function.start()] + EEVEE_SPECULAR + src[first_function.start():]
    for pattern, replacement in EEVEE_SPECULAR_EDITS:
        src, count = re.subn(pattern, lambda _: replacement, src, flags=re.S)
        if count != 1:
            raise RuntimeError('MaterialX specular code not found (%d matches): %s' % (count, pattern))
    for name, f0, f90, world_line, lamp_line, tint in EEVEE_SPECULAR_BSDFS:
        start = src.find('\nvoid %s(' % name)
        if start < 0:
            raise RuntimeError('MaterialX function not found: %s' % name)
        end = src.find('\n}\n', start)
        body = src[start:end]
        body, count = re.subn(r'mx_ggx_energy_compensation\(NdotV, avgAlpha, F\)',
                              'mx_ggx_energy_compensation(NdotV, avgAlpha, %s)' % f0, body)
        if count == 0:
            raise RuntimeError('No energy compensation in %s' % name)
        if body.count(world_line) != 1:
            raise RuntimeError('World reflection not found in %s' % name)
        body = body.replace(world_line, world_line.replace(
            'Li *', 'Li * mx_ggx_dir_albedo(NdotV, avgAlpha, %s, %s) *' % (f0, f90)))
        if name == 'mx_dielectric_bsdf':
            # Diffuse weighting (bsdf.throughput) uses the same F90
            body, count = re.subn(r'mx_ggx_dir_albedo\(NdotV, avgAlpha, F0, 1\.0\)',
                                  'mx_ggx_dir_albedo(NdotV, avgAlpha, F0, min(1.0, F0 / 0.0125))', body)
            if count == 0:
                raise RuntimeError('Dielectric directional albedo not found')
        if body.count(lamp_line) != 1:
            raise RuntimeError('Lamp reflection not found in %s' % name)
        body = body.replace(lamp_line, LAMP_RESPONSE % (f0, f90, tint))
        src = src[:start] + body + src[end:]
    return src


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name, is_array)."""
    found = []
    for kind, name, array in re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(\[[^\]]*\])?\s*(?:=[^;]*)?;', src, re.M):
        found.append((kind, name, bool(array)))
    return found
