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
"""
import re

LIGHT_VEC4S = 4

# The LightData struct MaterialX builds from Shaders/eevee/materialx/arm_lights.mtlx
LIGHT_MEMBERS = [
    ('int', 'type'), ('int', 'kind'), ('vec3', 'position'), ('vec3', 'direction'),
    ('vec3', 'color'), ('float', 'energy'), ('float', 'spot_size'), ('float', 'spot_blend'),
    ('float', 'cutoff'),
]

LIGHT_UNPACK = """
uniform vec4 u_lightPacked[MAX_LIGHT_SOURCES * %(n)d];

// Light layout, %(n)d vec4 per light (filled by armory.renderpath.eevee.EeveeLights):
//   0: type, kind, spot_size, spot_blend
//   1: position.xyz, energy
//   2: direction.xyz, cutoff
//   3: color.rgb, unused
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
    return light;
}
""" % {'n': LIGHT_VEC4S}

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


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name, is_array)."""
    found = []
    for kind, name, array in re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(\[[^\]]*\])?\s*(?:=[^;]*)?;', src, re.M):
        found.append((kind, name, bool(array)))
    return found
