"""Material export for the Eevee renderer (called from material/make.py parse()).

Every material draws with one MaterialX OpenPBR shader ("eevee_principled")
whose inputs are uniforms; each material sets them from its Principled BSDF
values. Node graphs come from Blender's own MaterialX export later.
"""
import hashlib
import os

import bpy

import arm
import arm.assets as assets
import arm.eevee.glsl_rewrite as glsl_rewrite
import arm.eevee.mx_codegen as mx_codegen
import arm.eevee.vertex as vertex
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    mx_codegen = arm.reload_module(mx_codegen)
    vertex = arm.reload_module(vertex)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

SHADER_NAME = 'eevee_principled'
SURFACE_ELEMENT = 'arm_surface'

# MaterialX uniforms the engine fills: name -> (shader data type, link)
ENGINE_CONSTANTS = {
    'u_viewPosition': ('vec3', '_cameraPosition'),
    'u_numActiveLightSources': ('int', '_eeveeLightCount'),
    'u_lightPacked': ('floats', '_eeveeLights'),
    'u_envMatrix': ('mat4', '_eeveeEnvMatrix'),
    'u_envLightIntensity': ('float', '_eeveeEnvIntensity'),
    'u_envRadianceMips': ('int', '_eeveeEnvMips'),
}
ENGINE_TEXTURES = {
    'u_envRadiance': {'link': '_eeveeEnvRadiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                      'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'linear'},
    'u_envIrradiance': {'link': '_eeveeEnvIrradiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                        'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
}
# Generated but unused with our options; left unbound.
IGNORED_UNIFORMS = {'u_envRadianceSamples', 'u_refractionTwoSided', 'backsurfaceshader', 'displacementshader1'}

# Principled BSDF socket -> (OpenPBR input, conversion). Follows Blender's own MaterialX export.
PRINCIPLED = [
    ('Base Color', 'base_color', 'rgb'),
    ('Metallic', 'base_metalness', 'float'),
    ('Roughness', 'specular_roughness', 'float'),
    ('IOR', 'specular_ior', 'float'),
    ('Specular IOR Level', 'specular_weight', 'double'),
    ('Specular Tint', 'specular_color', 'rgb'),
    ('Coat Weight', 'coat_weight', 'float'),
    ('Coat Roughness', 'coat_roughness', 'float'),
    ('Coat IOR', 'coat_ior', 'float'),
    ('Coat Tint', 'coat_color', 'rgb'),
    ('Sheen Weight', 'fuzz_weight', 'float'),
    ('Sheen Roughness', 'fuzz_roughness', 'float'),
    ('Sheen Tint', 'fuzz_color', 'rgb'),
    ('Emission Color', 'emission_color', 'rgb'),
    ('Emission Strength', 'emission_luminance', 'float'),
    ('Alpha', 'geometry_opacity', 'float'),
]

_shader_data = {}  # build folder -> shader data written during this session


def parse(material, mat_data, mat_users, mat_armusers):
    """Same contract as material/make.py parse(): returns (sd, rpasses, needs_sss)."""
    shader_data = write_shader()

    mat_data['contexts'].append({
        'name': 'mesh',
        'bind_constants': principled_constants(material),
        'bind_textures': [],
        'depth_read': False,
    })

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        mat_data['shader'] = SHADER_NAME
    else:
        ext = '' if wrd.arm_minimize else '.json'
        mat_data['shader'] = SHADER_NAME + ext + '/' + SHADER_NAME

    return shader_data, ['mesh'], False


def principled_constants(material) -> list:
    """Material uniforms from the Principled BSDF feeding the output (defaults otherwise)."""
    bsdf = surface_principled(material)
    constants = []
    for socket, name, kind in PRINCIPLED:
        value = bsdf.inputs[socket].default_value if bsdf is not None else None
        if kind == 'rgb':
            rgb = list(value)[:3] if value is not None else default_rgb(name)
            constants.append({'name': name, 'vec3Value': rgb})
        else:
            number = float(value) if value is not None else default_float(name)
            if kind == 'double' and value is not None:
                number *= 2.0  # Specular IOR Level 0.5 is OpenPBR specular_weight 1.0
            constants.append({'name': name, 'floatValue': number})
    return constants


def surface_principled(material):
    if material is None or not material.use_nodes or material.node_tree is None:
        return None
    for node in material.node_tree.nodes:
        if node.type == 'OUTPUT_MATERIAL' and node.is_active_output:
            links = node.inputs['Surface'].links
            if links and links[0].from_node.type == 'BSDF_PRINCIPLED':
                return links[0].from_node
    return None


def default_rgb(name):
    return [0.8, 0.8, 0.8] if name == 'base_color' else [1.0, 1.0, 1.0]


def default_float(name):
    return {'specular_roughness': 0.5, 'specular_ior': 1.5, 'specular_weight': 1.0, 'coat_roughness': 0.03,
            'coat_ior': 1.5, 'fuzz_roughness': 0.5, 'geometry_opacity': 1.0}.get(name, 0.0)


def write_shader():
    """Generates the shader (once per build folder and inputs) and writes its shader data."""
    build_shaders = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Shaders')
    frag_path = os.path.join(build_shaders, SHADER_NAME + '.frag.glsl')
    vert_path = os.path.join(build_shaders, SHADER_NAME + '.vert.glsl')
    if build_shaders in _shader_data and os.path.exists(frag_path) and os.path.exists(vert_path):
        register_shader_data(build_shaders, _shader_data[build_shaders])
        return _shader_data[build_shaders]
    os.makedirs(build_shaders, exist_ok=True)

    data_dir = os.path.join(arm.utils.get_sdk_path(), 'armory', 'Shaders', 'eevee', 'materialx')
    key_path = os.path.join(build_shaders, SHADER_NAME + '.key')
    key = generation_key(data_dir)
    if os.path.exists(frag_path) and os.path.exists(key_path) and open(key_path).read() == key:
        frag = open(frag_path, encoding='utf-8').read()
    else:
        frag = mx_codegen.generate_fragment(data_dir, os.path.join(data_dir, 'arm_principled.mtlx'), SHADER_NAME, SURFACE_ELEMENT)
        frag = glsl_rewrite.pack_lights(glsl_rewrite.flatten_varyings(frag))
        write_if_changed(frag_path, frag)
        with open(key_path, 'w') as f:
            f.write(key)

    vert, vertex_elements, vertex_constants = vertex.make(glsl_rewrite.inputs(frag))
    write_if_changed(vert_path, vert)

    constants, texture_units = fragment_bindings(frag)
    context = {
        'name': 'mesh',
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'clockwise',
        'vertex_elements': vertex_elements,
        'color_attachments': ['RGBA64'],
        'vertex_shader': SHADER_NAME + '.vert',
        'fragment_shader': SHADER_NAME + '.frag',
        # Not last: Iron's ArmPack reader peeks one byte past an array's length,
        # so an empty array at the very end of the file is read as null.
        'texture_units': texture_units,
        'constants': vertex_constants + constants,
    }
    shader_data = {'name': SHADER_NAME, 'contexts': [context]}
    _shader_data[build_shaders] = shader_data
    register_shader_data(build_shaders, shader_data)
    return shader_data


def fragment_bindings(frag: str) -> tuple:
    """Shader data constants and texture units for the generated pixel shader."""
    material_inputs = {name for _, name, _ in PRINCIPLED}
    constants = []
    texture_units = []
    for kind, name, is_array in glsl_rewrite.uniforms(frag):
        if name in ENGINE_CONSTANTS:
            ctype, link = ENGINE_CONSTANTS[name]
            constants.append({'name': name, 'type': ctype, 'link': link})
        elif name in ENGINE_TEXTURES:
            texture_units.append(dict({'name': name}, **ENGINE_TEXTURES[name]))
        elif name in material_inputs:
            constants.append({'name': name, 'type': kind})
        elif name not in IGNORED_UNIFORMS:
            raise RuntimeError('Eevee renderer: no binding for MaterialX uniform %s %s' % (kind, name))
    return constants, texture_units


def register_shader_data(build_shaders: str, shader_data: dict):
    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        from arm import exporter  # imported here: arm.exporter imports this module's caller
        output = exporter.current_output
        output.setdefault('shader_datas', [])
        if not any(sd['name'] == SHADER_NAME for sd in output['shader_datas']):
            output['shader_datas'].append(shader_data)
    else:
        path = os.path.join(build_shaders, SHADER_NAME + '.arm')
        arm.utils.write_arm(path, {'shader_datas': [shader_data]})
        assets.add_shader_data(path)


def generation_key(data_dir: str) -> str:
    """Changes whenever the generated shader could change."""
    digest = hashlib.sha1(mx_codegen.version().encode())
    here = os.path.dirname(os.path.abspath(__file__))
    paths = [os.path.join(data_dir, name) for name in sorted(os.listdir(data_dir))]
    paths += [os.path.join(here, name) for name in ('mx_codegen.py', 'glsl_rewrite.py')]
    for path in paths:
        with open(path, 'rb') as f:
            digest.update(f.read())
    return digest.hexdigest()


def write_if_changed(path: str, text: str):
    """Unchanged sources keep their timestamp, so khamake does not recompile them."""
    if os.path.exists(path) and open(path, encoding='utf-8').read() == text:
        return
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
