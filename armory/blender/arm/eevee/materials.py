"""Material export for the Eevee renderer (called from material/make.py parse()).

Every material renders from its own node graph, as Blender exports it to
MaterialX (mx_export). Its shader is the material pass: it writes the surface
values to the material images, which the lighting pass reads (RenderPathEevee).
Materials whose graphs differ only in their surface values share one shader
(mx_graph.prepare): those values are uniforms, set per material, and every
material binds its own textures.
"""
import hashlib
import os

import bpy

import arm
import arm.assets as assets
import arm.eevee.glsl_rewrite as glsl_rewrite
import arm.eevee.mx_codegen as mx_codegen
import arm.eevee.mx_export as mx_export
import arm.eevee.mx_graph as mx_graph
import arm.eevee.vertex as vertex
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    mx_codegen = arm.reload_module(mx_codegen)
    mx_export = arm.reload_module(mx_export)
    mx_graph = arm.reload_module(mx_graph)
    vertex = arm.reload_module(vertex)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

SHADER_PREFIX = 'eevee_mx_'
GBUFFER_CONTEXT = 'mesh'  # Iron's main object pass (tilesheets, GPU particles, debug draw hook on 'mesh')
SHADOW_CONTEXT = 'eevee_shadow'
GBUFFER_IMAGES = 5  # arm_gbuffer.glsl


_shaders = {}  # shader name -> (shader data, {image node: sampler uniform}), this session
_generation_key = None
_reported = set()  # materials already warned about this session

# Uniforms of arm_gbuffer.glsl the engine fills: name -> (shader data type, link)
ENGINE_CONSTANTS = {'u_armFrame': ('float', '_eeveeFrame')}


def parse(material, mat_data, mat_users, mat_armusers):
    """Same contract as material/make.py parse(): returns (sd, rpasses, needs_sss)."""
    path = mx_export.document(material)
    if path is None:
        raise RuntimeError('Eevee renderer: material "%s" has no MaterialX document '
                           '(see the export warnings above)' % material.name)
    prepared = mx_graph.prepare(path, mx_codegen.library(data_dir()))
    if prepared.problem:
        # Other shader nodes are exported as BSDF graphs the material images do not hold yet
        armory_pbr = material.node_tree is not None and any(
            node.type == 'GROUP' and node.node_tree is not None and node.node_tree.name.startswith('Armory PBR')
            for node in material.node_tree.nodes)
        raise RuntimeError('Eevee renderer: material "%s": %s' % (material.name,
                           'the Armory PBR node is not supported, use a Principled BSDF' if armory_pbr else
                           'only Principled BSDF, Diffuse BSDF and Emission surfaces are supported for now '
                           '(%s)' % prepared.problem))
    if material.name not in _reported:
        _reported.add(material.name)
        if prepared.dropped:
            log.warn('Eevee renderer: material "%s": not supported yet, rendered without: %s'
                     % (material.name, ', '.join(prepared.dropped)))
        if material.surface_render_method == 'BLENDED' and 'arm_gbuffer_cutout' in prepared.text:
            log.warn('Eevee renderer: material "%s": Blended transparency is not supported yet, '
                     'it renders as Dithered' % material.name)
    name = SHADER_PREFIX + hashlib.sha1((prepared.text + generation_key()).encode()).hexdigest()[:12]
    shader_data, samplers = write_shader(name, prepared)

    textures = []  # files are packed with compiled/Assets (mx_export.texture_folder())
    for node, file in prepared.textures.items():
        textures.append({'name': samplers[node], 'file': file, 'generate_mipmaps': True,
                         'u_addressing': 'repeat', 'v_addressing': 'repeat',
                         'min_filter': 'linear', 'mag_filter': 'linear', 'mipmap_filter': 'linear'})
    mat_data['contexts'].append({
        'name': GBUFFER_CONTEXT,
        'bind_constants': [constant(input_name, kind, value) for input_name, (kind, value) in sorted(prepared.values.items())],
        'bind_textures': textures,
        'depth_read': False,
    })
    mat_data['contexts'].append({'name': SHADOW_CONTEXT, 'bind_constants': [], 'bind_textures': []})

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        mat_data['shader'] = name
    else:
        ext = '' if wrd.arm_minimize else '.json'
        mat_data['shader'] = name + ext + '/' + name
    return shader_data, [GBUFFER_CONTEXT, SHADOW_CONTEXT], False


def constant(name: str, kind: str, value: str) -> dict:
    if kind == 'boolean':
        return {'name': name, 'boolValue': value == 'true'}
    numbers = [float(v) for v in value.replace(',', ' ').split()]
    if kind in ('color3', 'vector3'):
        return {'name': name, 'vec3Value': numbers[:3]}
    if kind == 'float':
        return {'name': name, 'floatValue': numbers[0]}
    raise RuntimeError('Eevee renderer: unsupported surface uniform %s (%s)' % (name, kind))


def write_shader(name: str, prepared) -> tuple:
    """Generates the shader for a canonical document (once per build folder) and
    registers its shader data. Returns (shader data, {image node: sampler})."""
    build_shaders = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Shaders')
    frag_path = os.path.join(build_shaders, name + '.frag.glsl')
    if name in _shaders and os.path.exists(frag_path):
        register_shader_data(build_shaders, name, _shaders[name][0])
        return _shaders[name]
    os.makedirs(build_shaders, exist_ok=True)

    if not os.path.exists(frag_path):
        document_path = os.path.join(build_shaders, name + '.mtlx')
        with open(document_path, 'w', encoding='utf-8') as f:
            f.write(prepared.text)
        frag = mx_codegen.generate_fragment(data_dir(), document_path, name, mx_graph.SURFACE_NODE)
        frag = glsl_rewrite.flatten_varyings(frag)
        frag = glsl_rewrite.gbuffer_output(frag)
        with open(frag_path, 'w', encoding='utf-8') as f:
            f.write(frag)
    frag = open(frag_path, encoding='utf-8').read()

    vert, vertex_elements, vertex_constants = vertex.make(glsl_rewrite.inputs(frag))
    write_if_changed(os.path.join(build_shaders, name + '.vert.glsl'), vert)

    constants, texture_units, samplers = fragment_bindings(frag, set(prepared.values), set(prepared.textures))
    context = {
        'name': GBUFFER_CONTEXT,
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'clockwise',
        'vertex_elements': vertex_elements,
        'color_attachments': ['RGBA64'] * GBUFFER_IMAGES,
        'vertex_shader': name + '.vert',
        'fragment_shader': name + '.frag',
        # Not last: Iron's ArmPack reader peeks one byte past an array's length,
        # so an empty array at the very end of the file is read as null.
        'texture_units': texture_units,
        'constants': vertex_constants + constants,
    }
    shadow_vert, shadow_frag, shadow_elements, shadow_constants = vertex.make_shadow()
    write_if_changed(os.path.join(build_shaders, 'eevee_shadow.vert.glsl'), shadow_vert)
    write_if_changed(os.path.join(build_shaders, 'eevee_shadow.frag.glsl'), shadow_frag)
    shadow_context = {
        'name': SHADOW_CONTEXT,
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'none',  # Eevee casts from both sides unless use_backface_culling_shadow
        'vertex_elements': shadow_elements,
        'color_attachments': ['R32'],
        'vertex_shader': 'eevee_shadow.vert',
        'fragment_shader': 'eevee_shadow.frag',
        'texture_units': [],
        'constants': shadow_constants,
    }
    shader_data = {'name': name, 'contexts': [context, shadow_context]}
    _shaders[name] = (shader_data, samplers)
    register_shader_data(build_shaders, name, shader_data)
    return _shaders[name]


def fragment_bindings(frag: str, surface_inputs: set, image_nodes: set) -> tuple:
    """Shader data constants and texture units for a generated pixel shader, and
    the sampler of each image node (bound by every material to its own file).
    Surface inputs are set by every material (mx_graph.Prepared.values)."""
    constants = []
    texture_units = []
    samplers = {}
    for kind, name, is_array in glsl_rewrite.uniforms(frag):
        if name in surface_inputs:
            constants.append({'name': name, 'type': kind})
        elif name in ENGINE_CONSTANTS:
            ctype, link = ENGINE_CONSTANTS[name]
            constants.append({'name': name, 'type': ctype, 'link': link})
        elif kind == 'sampler2D' and name.split('_')[0] in image_nodes:
            texture_units.append({'name': name})
            samplers[name.split('_')[0]] = name
        else:
            raise RuntimeError('Eevee renderer: no binding for MaterialX uniform %s %s' % (kind, name))
    missing = image_nodes - set(samplers)
    if missing:
        raise RuntimeError('Eevee renderer: no sampler generated for image nodes %s' % sorted(missing))
    return constants, texture_units, samplers


def register_shader_data(build_shaders: str, name: str, shader_data: dict):
    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        from arm import exporter  # imported here: arm.exporter imports this module's caller
        output = exporter.current_output
        output.setdefault('shader_datas', [])
        if not any(sd['name'] == name for sd in output['shader_datas']):
            output['shader_datas'].append(shader_data)
    else:
        path = os.path.join(build_shaders, name + '.arm')
        arm.utils.write_arm(path, {'shader_datas': [shader_data]})
        assets.add_shader_data(path)


def data_dir() -> str:
    return os.path.join(arm.utils.get_sdk_path(), 'armory', 'Shaders', 'eevee', 'materialx')


def generation_key() -> str:
    """Changes whenever a generated shader could change: shader names include it."""
    global _generation_key
    if _generation_key is None:
        digest = hashlib.sha1(mx_codegen.version().encode())
        here = os.path.dirname(os.path.abspath(__file__))
        paths = [os.path.join(data_dir(), n) for n in sorted(os.listdir(data_dir()))]
        paths += [os.path.join(here, n) for n in ('mx_codegen.py', 'mx_graph.py', 'glsl_rewrite.py', 'vertex.py')]
        for path in paths:
            with open(path, 'rb') as f:
                digest.update(f.read())
        _generation_key = digest.hexdigest()
    return _generation_key


def write_if_changed(path: str, text: str):
    """Unchanged sources keep their timestamp, so khamake does not recompile them."""
    if os.path.exists(path) and open(path, encoding='utf-8').read() == text:
        return
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
