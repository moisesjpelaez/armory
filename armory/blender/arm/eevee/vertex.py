"""Vertex stage for MaterialX pixel shaders.

MaterialX's own vertex shader expects plain float vertex data; Armory meshes are
packed (pos.xyz + nor.z in a short4norm, nor.xy in a short2norm, texture
coordinates scaled by texUnpack). This writes a vertex shader that reads the
packed data and outputs exactly the varyings the pixel shader declares, in the
same order (D3D11 links the stages by register order).

Skinned meshes (`skin`) are deformed here, as Blender's Armature modifier does:
LINEAR blends the bones' matrices (Preserve Volume off, Blender's default),
DUAL blends dual quaternions (Preserve Volume on). Bones and weights come from
Armory's mesh data (4 per vertex); the bone data from armory.renderpath.eevee
(EeveeUniforms), last frame's too for the motion vectors.
"""

LINEAR = 'linear'
DUAL = 'dual'
MAX_BONES = 128  # iron.object.BoneAnimation.skinMaxBones

# Varying name (after glsl_rewrite) -> (GLSL computing it, uniforms it needs).
# Locals available: positionWorld, normalWorld, tangentWorld (world space),
# objectPos / objectNor (object space, after skinning), prevObjectPos.
VARYINGS = {
    'vd_positionWorld': ('positionWorld.xyz', []),
    # Object space (Texture Coordinate > Object)
    'vd_positionObject': ('objectPos', []),
    'vd_normalObject': ('normalize(objectNor)', []),
    'vd_normalWorld': ('normalWorld', []),
    'vd_tangentWorld': ('tangentWorld', []),
    'vd_bitangentWorld': ('cross(normalWorld, tangentWorld)', []),
    'vd_texcoord_0': ('tex * texUnpack', ['texUnpack']),
    # Unjittered clip positions now and last frame, for the velocity output
    'vd_armClip': ('armVP * positionWorld', ['armVP']),
    'vd_armPrevClip': ('armPrevVP * (prevW * vec4(prevObjectPos / posUnpack, 1.0))', ['armPrevVP', 'prevW']),
}

UNIFORMS = {
    'texUnpack': ('float', '_texUnpack'),
    'posUnpack': ('float', '_posUnpack'),
    'armVP': ('mat4', '_eeveeVP'),
    'armPrevVP': ('mat4', '_eeveePrevVP'),
    'prevW': ('mat4', '_prevWorldMatrix'),
}

# Bone data: (name, vec4 per bone, link) for this frame and last frame
SKIN_BUFFERS = {
    LINEAR: (('skinMatrices', 3, '_eeveeSkinMatrices'), ('skinMatricesPrev', 3, '_eeveeSkinMatricesPrev')),
    DUAL: (('skinBones', 2, '_skinBones'), ('skinBonesPrev', 2, '_eeveeSkinBonesPrev')),
}

SKIN_LINEAR = """
// Linear blend skinning: 3 rows of the bone's matrix per bone
void arm_skin_%(buf)s(vec3 p, vec3 n, out vec3 sp, out vec3 sn)
{
    sp = vec3(0.0);
    sn = vec3(0.0);
    for (int k = 0; k < 4; k++)
    {
        int b = armBones[k] * 3;
        vec4 r0 = %(buf)s[b];
        vec4 r1 = %(buf)s[b + 1];
        vec4 r2 = %(buf)s[b + 2];
        sp += weight[k] * vec3(dot(r0, vec4(p, 1.0)), dot(r1, vec4(p, 1.0)), dot(r2, vec4(p, 1.0)));
        sn += weight[k] * vec3(dot(r0.xyz, n), dot(r1.xyz, n), dot(r2.xyz, n));
    }
}
"""

SKIN_DUAL = """
// Dual quaternion skinning (Kavan et al. 2008): real and dual part per bone,
// blended in the hemisphere of the first bone
void arm_skin_%(buf)s(vec3 p, vec3 n, out vec3 sp, out vec3 sn)
{
    vec4 first = %(buf)s[armBones[0] * 2];
    vec4 real = vec4(0.0);
    vec4 dual = vec4(0.0);
    for (int k = 0; k < 4; k++)
    {
        vec4 r = %(buf)s[armBones[k] * 2];
        float w = dot(r, first) < 0.0 ? -weight[k] : weight[k];
        real += w * r;
        dual += w * %(buf)s[armBones[k] * 2 + 1];
    }
    float inv = 1.0 / length(real);
    real *= inv;
    dual *= inv;
    sp = p + 2.0 * cross(real.xyz, cross(real.xyz, p) + real.w * p)
           + 2.0 * (real.w * dual.xyz - dual.w * real.xyz + cross(real.xyz, dual.xyz));
    sn = n + 2.0 * cross(real.xyz, cross(real.xyz, n) + real.w * n);
}
"""


def skin_declarations(skin: str, constants: list, lines: list, previous: bool):
    """Declares the bone data and skinning functions; returns the buffers' names."""
    lines.append('#define ARM_MAX_BONES %d' % MAX_BONES)
    buffers = SKIN_BUFFERS[skin] if previous else SKIN_BUFFERS[skin][:1]
    for name, vec4s, link in buffers:
        constants.append({'name': name, 'type': 'floats', 'link': link})
        lines.append('uniform vec4 %s[ARM_MAX_BONES * %d];' % (name, vec4s))
    lines.append('ivec4 armBones;')
    for name, _, _ in buffers:
        lines.append((SKIN_LINEAR if skin == LINEAR else SKIN_DUAL) % {'buf': name})
    return [name for name, _, _ in buffers]


def skin_elements(elements: list, lines: list):
    elements += [{'name': 'bone', 'data': 'short4norm'}, {'name': 'weight', 'data': 'short4norm'}]
    lines += ['in vec4 bone;', 'in vec4 weight;']


def make(varyings: list, skin: str = None) -> tuple:
    """varyings: [(type, name)] from the pixel shader; skin: None, LINEAR or DUAL.
    Returns (source, vertex_elements, constants)."""
    names = [name for _, name in varyings]
    unknown = [name for name in names if name not in VARYINGS]
    if unknown:
        raise RuntimeError('No vertex recipe for MaterialX varyings: %s' % unknown)
    extra = ['posUnpack']
    for name in names:
        for uniform in VARYINGS[name][1]:
            if uniform not in extra:
                extra.append(uniform)

    elements = [{'name': 'pos', 'data': 'short4norm'}, {'name': 'nor', 'data': 'short2norm'}]
    constants = [
        {'name': 'W', 'type': 'mat4', 'link': '_worldMatrix'},
        {'name': 'N', 'type': 'mat3', 'link': '_normalMatrix'},
        {'name': 'VP', 'type': 'mat4', 'link': '_viewProjectionMatrix'},
    ]
    lines = ['#version 450', '', 'in vec4 pos;', 'in vec2 nor;']
    if 'vd_texcoord_0' in names:
        elements.append({'name': 'tex', 'data': 'short2norm'})
        lines.append('in vec2 tex;')
    if skin:
        skin_elements(elements, lines)
    lines += ['', 'uniform mat4 W;', 'uniform mat3 N;', 'uniform mat4 VP;']
    for uniform in extra:
        kind, link = UNIFORMS[uniform]
        constants.append({'name': uniform, 'type': kind, 'link': link})
        lines.append('uniform %s %s;' % (kind, uniform))
    buffers = skin_declarations(skin, constants, lines, 'vd_armPrevClip' in names) if skin else []
    lines.append('')
    lines += ['out %s %s;' % (kind, name) for kind, name in varyings]
    lines += [
        '',
        'void main() {',
        '\tvec3 objectPos = pos.xyz * posUnpack;',
        '\tvec3 objectNor = vec3(nor.xy, pos.w);',
        '\tvec3 prevObjectPos = objectPos;',
    ]
    if skin:
        lines.append('\tarmBones = ivec4(bone * 32767.0 + 0.5);')
        if len(buffers) > 1:
            lines.append('\tvec3 prevNor;')
            lines.append('\tarm_skin_%s(objectPos, objectNor, prevObjectPos, prevNor);' % buffers[1])
        lines.append('\tarm_skin_%s(objectPos, objectNor, objectPos, objectNor);' % buffers[0])
    lines += [
        '\tvec4 positionWorld = W * vec4(objectPos / posUnpack, 1.0);',
        '\tvec3 normalWorld = normalize(N * objectNor);',
        '\t// No tangents exported yet: any unit vector perpendicular to the normal.',
        '\t// It must never be parallel to it, MaterialX normalizes T - N * dot(T, N).',
        '\tvec3 helper = abs(normalWorld.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);',
        '\tvec3 tangentWorld = normalize(cross(helper, normalWorld));',
    ]
    lines += ['\t%s = %s;' % (name, VARYINGS[name][0]) for name in names]
    lines += ['\tgl_Position = VP * positionWorld;', '}', '']
    return '\n'.join(lines), elements, constants


def make_shadow(skin: str = None) -> tuple:
    """Depth-only pass into a shadow tile (EeveeShadows): returns (vertex source,
    pixel source, vertex_elements, constants). The tile matrix maps world space
    straight to clip space; the pixel stage stores the view's linear depth 0..1
    (shadowDepth row) in an R32 target."""
    elements = [{'name': 'pos', 'data': 'short4norm'}]
    constants = [
        {'name': 'W', 'type': 'mat4', 'link': '_worldMatrix'},
        {'name': 'shadowVP', 'type': 'mat4', 'link': '_eeveeShadowVP'},
        {'name': 'shadowDepth', 'type': 'vec4', 'link': '_eeveeShadowDepth'},
    ]
    lines = ['#version 450', '', 'in vec4 pos;']
    if skin:
        elements.append({'name': 'nor', 'data': 'short2norm'})
        lines.append('in vec2 nor;')
        skin_elements(elements, lines)
        constants.append({'name': 'posUnpack', 'type': 'float', 'link': '_posUnpack'})
    lines += ['', 'uniform mat4 W;', 'uniform mat4 shadowVP;', 'uniform vec4 shadowDepth;']
    if skin:
        lines.append('uniform float posUnpack;')
        skin_declarations(skin, constants, lines, False)
    lines += ['', 'out float depth;', '', 'void main() {']
    if skin:
        lines += [
            '\tarmBones = ivec4(bone * 32767.0 + 0.5);',
            '\tvec3 objectPos;',
            '\tvec3 objectNor;',
            '\tarm_skin_%s(pos.xyz * posUnpack, vec3(nor.xy, pos.w), objectPos, objectNor);' % SKIN_BUFFERS[skin][0][0],
            '\tvec4 positionWorld = W * vec4(objectPos / posUnpack, 1.0);',
        ]
    else:
        lines.append('\tvec4 positionWorld = W * vec4(pos.xyz, 1.0);')
    lines += [
        '\tgl_Position = shadowVP * positionWorld;',
        '\tdepth = dot(shadowDepth.xyz, positionWorld.xyz) + shadowDepth.w;',
        '}',
        '',
    ]
    vert = '\n'.join(lines)
    frag = '\n'.join([
        '#version 450',
        '',
        'in float depth;',
        'out vec4 fragColor;',
        '',
        'void main() {',
        '\tfragColor = vec4(depth, 0.0, 0.0, 1.0);',
        '}',
        '',
    ])
    return vert, frag, elements, constants
