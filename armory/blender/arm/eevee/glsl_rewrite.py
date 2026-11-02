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

shadow_normal: the shadow lookup (SHADOWS, declared with the lights) needs the
    geometric normal for its normal offset.
"""
import re

LIGHT_VEC4S = 6
MAX_SHADOW_VIEWS = 16  # EeveeShadows.MAX_VIEWS
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
// Shadow views, 4 vec4 each (filled by armory.renderpath.eevee.EeveeShadows):
//   0-2: rows mapping a world position to the tile's u, v (0..1, v down) and depth (0..1)
//   3: the tile in the atlas: x, y, width, height (0..1)
uniform vec4 u_armShadows[ARM_MAX_SHADOW_VIEWS * 4];
// x = 1 / atlas size in texels
uniform vec4 u_armShadowInfo;
uniform sampler2D u_armShadowMap;
// Geometric normal of the shaded point (set at the start of main), for the normal offset
vec3 arm_geomNormal;

float arm_shadow_depth(vec2 texel)
{
    return textureLod(u_armShadowMap, (texel + 0.5) * u_armShadowInfo.x, 0.0).r;
}

// Visibility of `position` in one shadow view; `inside` is false outside its tile.
float arm_shadow_view(int view, vec3 position, vec3 toLight, out bool inside)
{
    vec4 r0 = u_armShadows[view * 4 + 0];
    vec4 r1 = u_armShadows[view * 4 + 1];
    vec4 r2 = u_armShadows[view * 4 + 2];
    vec4 rect = u_armShadows[view * 4 + 3];
    float tileTexels = rect.z / u_armShadowInfo.x;
    // One shadow texel in metres; offset along the normal, more at grazing light
    float texelWorld = 1.0 / (length(r0.xyz) * tileTexels);
    float nl = clamp(dot(arm_geomNormal, toLight), 0.0, 1.0);
    vec3 p = position + arm_geomNormal * texelWorld * (0.5 + 1.5 * sqrt(1.0 - nl * nl));
    vec3 uvw = vec3(dot(r0.xyz, p) + r0.w, dot(r1.xyz, p) + r1.w, dot(r2.xyz, p) + r2.w);
    float margin = 1.0 / tileTexels;
    // A tile is a column along the light: also inside its depth range
    inside = all(greaterThan(uvw.xy, vec2(margin))) && all(lessThan(uvw.xy, vec2(1.0 - margin))) && uvw.z < 1.0;
    if (!inside) return 1.0;
    float depth = uvw.z - texelWorld * length(r2.xyz) * 0.5;
    // Bilinear-weighted 2x2 comparison
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

// Visibility of `position` from the light; suns pick the finest cascade containing it.
float arm_shadow(LightData light, vec3 position, vec3 toLight)
{
    if (light.shadow < 0.0) return 1.0;
    int first = int(light.shadow);
    int count = light.kind == 0 ? %(cascades)d : 1;
    for (int i = 0; i < %(cascades)d; i++)
    {
        if (i >= count) break;
        bool inside;
        float visibility = arm_shadow_view(first + i, position, toLight, inside);
        if (inside) return visibility;
    }
    return 1.0;
}
""" % {'views': MAX_SHADOW_VIEWS, 'cascades': SUN_CASCADES}

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


def velocity_output(src: str) -> str:
    """Adds a second output with the pixel's screen motion for temporal anti-aliasing:
    current minus previous NDC position, from unjittered clip positions the vertex
    stage passes in (vertex.py)."""
    output = re.compile(r'^out vec4 (\w+);', re.M)
    match = output.search(src)
    if match is None:
        raise RuntimeError('MaterialX pixel output not found')
    declarations = ('layout(location = 0) out vec4 %s;\n'
                    'layout(location = 1) out vec4 armVelocity;\n'
                    'in vec4 vd_armClip;\n'
                    'in vec4 vd_armPrevClip;' % match.group(1))
    src = src[:match.start()] + declarations + src[match.end():]
    main = re.compile(r'(\nvoid main\(\)\s*\{)')
    if not main.search(src):
        raise RuntimeError('MaterialX main() not found')
    write = ('\n    armVelocity = vec4(vd_armClip.xy / vd_armClip.w - vd_armPrevClip.xy / vd_armPrevClip.w, 0.0, 1.0);')
    return main.sub(lambda m: m.group(1) + write, src, count=1)


def shadow_normal(src: str) -> str:
    """Sets arm_geomNormal (used by the shadow lookup) at the start of main()."""
    main = re.compile(r'(\nvoid main\(\)\s*\{)')
    if not main.search(src):
        raise RuntimeError('MaterialX main() not found')
    return main.sub(lambda m: m.group(1) + '\n    arm_geomNormal = normalize(vd_normalWorld);', src, count=1)


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
        float omega = max(arm_polygon_solid_angle(arm_lampCount), 1e-12);
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
    # World reflection: the table replaces MaterialX's F * G (applied at the call sites)
    (r'vec3 FG = fd\.refraction \? vec3\(1\.0\) - \(F \* G\) : F \* G;',
     'vec3 FG = fd.refraction ? vec3(1.0) - (F * G) : vec3(1.0);'),
]

# Per BSDF function: (function name, F0 expression, F90 expression, its world reflection
# line, its lamp reflection line, the lamp reflection's tint factor)
EEVEE_SPECULAR_BSDFS = [
    ('mx_dielectric_bsdf', 'vec3(F0)', 'vec3(1.0)', 'bsdf.response = Li * safeTint * comp * weight;',
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
