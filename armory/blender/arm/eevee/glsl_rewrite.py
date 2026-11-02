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
"""
import re

LIGHT_VEC4S = 4

# The LightData struct MaterialX builds from Shaders/eevee/materialx/arm_lights.mtlx
LIGHT_MEMBERS = [
    ('int', 'type'), ('int', 'kind'), ('vec3', 'position'), ('vec3', 'direction'),
    ('vec3', 'color'), ('float', 'energy'), ('float', 'spot_size'), ('float', 'spot_blend'),
]

LIGHT_UNPACK = """
uniform vec4 u_lightPacked[MAX_LIGHT_SOURCES * %(n)d];

// Light layout, %(n)d vec4 per light (filled by armory.renderpath.eevee.EeveeLights):
//   0: type, kind, spot_size, spot_blend
//   1: position.xyz, energy
//   2: direction.xyz, unused
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
    light.color = d.xyz;
    return light;
}
""" % {'n': LIGHT_VEC4S}


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


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name, is_array)."""
    found = []
    for kind, name, array in re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(\[[^\]]*\])?\s*(?:=[^;]*)?;', src, re.M):
        found.append((kind, name, bool(array)))
    return found
