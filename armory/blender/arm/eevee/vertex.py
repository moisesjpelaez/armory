"""Vertex stage for MaterialX pixel shaders.

MaterialX's own vertex shader expects plain float vertex data; Armory meshes are
packed (pos.xyz + nor.z in a short4norm, nor.xy in a short2norm, texture
coordinates scaled by texUnpack). This writes a vertex shader that reads the
packed data and outputs exactly the varyings the pixel shader declares, in the
same order (D3D11 links the stages by register order).
"""

# Varying name (after glsl_rewrite.flatten_varyings) -> GLSL computing it.
# `positionWorld`, `normalWorld` and `tangentWorld` are always available as locals.
VARYINGS = {
    'vd_positionWorld': 'positionWorld.xyz',
    'vd_normalWorld': 'normalWorld',
    'vd_tangentWorld': 'tangentWorld',
    'vd_bitangentWorld': 'cross(normalWorld, tangentWorld)',
    'vd_texcoord_0': 'tex * texUnpack',
}


def make(varyings: list) -> tuple:
    """varyings: [(type, name)] from the pixel shader. Returns (source, vertex_elements, constants)."""
    names = [name for _, name in varyings]
    unknown = [name for name in names if name not in VARYINGS]
    if unknown:
        raise RuntimeError('No vertex recipe for MaterialX varyings: %s' % unknown)

    uses_tex = 'vd_texcoord_0' in names
    elements = [{'name': 'pos', 'data': 'short4norm'}, {'name': 'nor', 'data': 'short2norm'}]
    constants = [
        {'name': 'W', 'type': 'mat4', 'link': '_worldMatrix'},
        {'name': 'N', 'type': 'mat3', 'link': '_normalMatrix'},
        {'name': 'VP', 'type': 'mat4', 'link': '_viewProjectionMatrix'},
    ]
    lines = ['#version 450', '', 'in vec4 pos;', 'in vec2 nor;']
    if uses_tex:
        elements.append({'name': 'tex', 'data': 'short2norm'})
        constants.append({'name': 'texUnpack', 'type': 'float', 'link': '_texUnpack'})
        lines.append('in vec2 tex;')
    lines += ['', 'uniform mat4 W;', 'uniform mat3 N;', 'uniform mat4 VP;']
    if uses_tex:
        lines.append('uniform float texUnpack;')
    lines.append('')
    lines += ['out %s %s;' % (kind, name) for kind, name in varyings]
    lines += [
        '',
        'void main() {',
        '\tvec4 positionWorld = W * vec4(pos.xyz, 1.0);',
        '\tvec3 normalWorld = normalize(N * vec3(nor.xy, pos.w));',
        '\t// No tangents exported yet: any unit vector perpendicular to the normal.',
        '\t// It must never be parallel to it, MaterialX normalizes T - N * dot(T, N).',
        '\tvec3 helper = abs(normalWorld.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);',
        '\tvec3 tangentWorld = normalize(cross(helper, normalWorld));',
    ]
    lines += ['\t%s = %s;' % (name, VARYINGS[name]) for name in names]
    lines += ['\tgl_Position = VP * positionWorld;', '}', '']
    return '\n'.join(lines), elements, constants
