"""Vertex stages for the material pass and the shadow pass.

The shaders are templates in Shaders/eevee (eevee_mesh.vert.glsl,
eevee_shadow.vert.glsl, eevee_skin.inc); this module only picks their options:
texture coordinates, skinning (LINEAR or DUAL, as Blender's Armature modifier),
and the varyings the material's pixel shader declares, in its order (D3D11 links
the stages by register order). Vertex elements and constants are read from the
resolved shader, so the shader data always matches what is compiled.
"""
import re

import arm
import arm.eevee.engine as engine
import arm.eevee.files as files

if arm.is_reload(__name__):
    engine = arm.reload_module(engine)
    files = arm.reload_module(files)
else:
    arm.enable_reload(__name__)

LINEAR = 'linear'
DUAL = 'dual'

# Varying name (after glsl_rewrite) -> GLSL computing it in eevee_mesh.vert.glsl's main()
VARYINGS = {
    'vd_positionWorld': 'positionWorld.xyz',
    'vd_positionObject': 'objectPos',
    'vd_normalObject': 'normalize(objectNor)',
    'vd_normalWorld': 'normalWorld',
    'vd_tangentWorld': 'tangentWorld',
    'vd_bitangentWorld': 'cross(normalWorld, tangentWorld)',
    'vd_texcoord_0': 'tex * texUnpack',
    'vd_armClip': 'armVP * positionWorld',
    'vd_armPrevClip': 'armPrevVP * (prevW * vec4(prevObjectPos / posUnpack, 1.0))',
}

# Vertex inputs Armory's meshes provide
ELEMENTS = {'pos': 'short4norm', 'nor': 'short2norm', 'tex': 'short2norm', 'bone': 'short4norm', 'weight': 'short4norm'}

# Uniforms of the templates -> (shader data type, link)
CONSTANTS = {
    'W': ('mat4', '_worldMatrix'),
    'N': ('mat3', '_normalMatrix'),
    'VP': ('mat4', '_viewProjectionMatrix'),
    'posUnpack': ('float', '_posUnpack'),
    'texUnpack': ('float', '_texUnpack'),
    'armVP': ('mat4', '_eeveeVP'),
    'armPrevVP': ('mat4', '_eeveePrevVP'),
    'prevW': ('mat4', '_prevWorldMatrix'),
    'shadowVP': ('mat4', '_eeveeShadowVP'),
    'shadowDepth': ('vec4', '_eeveeShadowDepth'),
    'skinMatrices': ('floats', '_eeveeSkinMatrices'),
    'skinMatricesPrev': ('floats', '_eeveeSkinMatricesPrev'),
    'skinBones': ('floats', '_skinBones'),
    'skinBonesPrev': ('floats', '_eeveeSkinBonesPrev'),
}


def make(varyings: list, skin: str = None) -> tuple:
    """varyings: [(type, name)] from the pixel shader; skin: None, LINEAR or DUAL.
    Returns (source, vertex_elements, constants)."""
    unknown = [name for _, name in varyings if name not in VARYINGS]
    if unknown:
        raise RuntimeError('No vertex recipe for MaterialX varyings: %s' % unknown)
    names = [name for _, name in varyings]
    flags = skin_flags(skin, previous=True)
    if 'vd_texcoord_0' in names:
        flags.add('ARM_TEXCOORD')
    source = files.resolve('eevee_mesh.vert.glsl', flags, {'ARM_MAX_BONES': engine.max_bones()} if skin else None)
    source = source.replace('// @varyings', '\n'.join('out %s %s;' % v for v in varyings))
    source = source.replace('\t// @writes', '\n'.join('\t%s = %s;' % (name, VARYINGS[name]) for name in names))
    return (source,) + bindings(source)


def make_shadow(skin: str = None) -> tuple:
    """Depth-only pass into a shadow tile: returns (vertex source, pixel source,
    vertex_elements, constants)."""
    vert = files.resolve('eevee_shadow.vert.glsl', skin_flags(skin, previous=False),
                         {'ARM_MAX_BONES': engine.max_bones()} if skin else None)
    with open(files.sdk_shaders('eevee_shadow.frag.glsl'), encoding='utf-8') as f:
        frag = f.read()
    return (vert, frag) + bindings(vert)


def skin_flags(skin: str, previous: bool) -> set:
    if skin is None:
        return set()
    flags = {'ARM_SKIN', 'ARM_SKIN_LINEAR' if skin == LINEAR else 'ARM_SKIN_DUAL'}
    if previous:
        flags.add('ARM_SKIN_PREVIOUS')
    return flags


def bindings(source: str) -> tuple:
    """Vertex elements and constants of a resolved vertex shader."""
    elements = [{'name': name, 'data': ELEMENTS[name]} for name in re.findall(r'^in\s+\w+\s+(\w+)\s*;', source, re.M)]
    constants = []
    for name in re.findall(r'^uniform\s+\w+\s+(\w+)', source, re.M):
        kind, link = CONSTANTS[name]
        constants.append({'name': name, 'type': kind, 'link': link})
    return elements, constants
