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
import arm.eevee.context as context
import arm.assets as assets
import arm.eevee.engine as engine
import arm.eevee.files as files
import arm.eevee.glsl_rewrite as glsl_rewrite
import arm.eevee.mx_codegen as mx_codegen
import arm.eevee.mx_export as mx_export
import arm.eevee.mx_graph as mx_graph
import arm.eevee.vertex as vertex
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    context = arm.reload_module(context)
    engine = arm.reload_module(engine)
    files = arm.reload_module(files)
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
HASH_LENGTH = 12  # shader base name: SHADER_PREFIX + this many hex digits of the document's hash
GBUFFER_CONTEXT = 'mesh'  # Iron's main object pass (tilesheets, GPU particles, debug draw hook on 'mesh')

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
    if context.warn_once('material', material.name):
        if prepared.dropped:
            log.warn('Eevee renderer: material "%s": not supported yet, rendered without: %s'
                     % (material.name, ', '.join(prepared.dropped)))
        if material.surface_render_method == 'BLENDED' and prepared.cutout:
            log.warn('Eevee renderer: material "%s": Blended transparency is not supported yet, '
                     'it renders as Dithered' % material.name)
    base = SHADER_PREFIX + hashlib.sha1((prepared.text + generation_key()).encode()).hexdigest()[:HASH_LENGTH]
    skin = skinning(material, mat_users)
    name = base + '_' + skin if skin else base  # skinned meshes share the pixel shader, not the vertex shader
    shader_data, samplers = write_shader(name, base, prepared, skin)

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
    mat_data['contexts'].append({'name': engine.shadow_context(), 'bind_constants': [], 'bind_textures': []})

    # Blender's Backface Culling (off by default: both sides are drawn), not
    # Armory's own culling settings, which the exporter sets before this call.
    # The shader culls back faces; the shadow context draws both sides anyway.
    mat_data.pop('override_context', None)
    if not material.use_backface_culling:
        mat_data['override_context'] = {'cull_mode': 'none'}

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        mat_data['shader'] = name
    else:
        ext = '' if wrd.arm_minimize else '.json'
        mat_data['shader'] = name + ext + '/' + name
    return shader_data, [GBUFFER_CONTEXT, engine.shadow_context()], False


def constant(name: str, kind: str, value: str) -> dict:
    if kind == 'boolean':
        return {'name': name, 'boolValue': value == 'true'}
    numbers = [float(v) for v in value.replace(',', ' ').split()]
    if kind in ('color3', 'vector3'):
        return {'name': name, 'vec3Value': numbers[:3]}
    if kind == 'float':
        return {'name': name, 'floatValue': numbers[0]}
    raise RuntimeError('Eevee renderer: unsupported surface uniform %s (%s)' % (name, kind))


def skinning(material, mat_users) -> str:
    """vertex.LINEAR or vertex.DUAL for a material on skinned meshes (Blender's
    Armature modifier: dual quaternions with Preserve Volume), None otherwise."""
    modes = set()
    for obj in mat_users.get(material, []):
        if arm.utils.export_bone_data(obj):
            modifier = next((m for m in obj.modifiers if m.type == 'ARMATURE'), None)
            modes.add(vertex.DUAL if modifier is not None and modifier.use_deform_preserve_volume else vertex.LINEAR)
    if len(modes) > 1:
        raise RuntimeError('Eevee renderer: material "%s" is used by skinned meshes with and without the '
                           "Armature modifier's Preserve Volume; use one setting for all of them" % material.name)
    return modes.pop() if modes else None


def write_shader(name: str, base: str, prepared, skin: str) -> tuple:
    """Generates the shader for a canonical document (once per build folder) and
    registers its shader data. Returns (shader data, {image node: sampler})."""
    build_shaders = files.build_shaders()
    frag_path = os.path.join(build_shaders, base + '.frag.glsl')
    shaders = context.current().shaders
    if name in shaders and os.path.exists(frag_path):
        register_shader_data(build_shaders, name, shaders[name][0])
        return shaders[name]

    if not os.path.exists(frag_path):
        document_path = os.path.join(build_shaders, base + '.mtlx')
        with open(document_path, 'w', encoding='utf-8') as f:
            f.write(prepared.text)
        frag = mx_codegen.generate_fragment(data_dir(), document_path, base, mx_graph.SURFACE_NODE)
        frag = glsl_rewrite.flatten_varyings(frag)
        frag = glsl_rewrite.gbuffer_output(frag)
        with open(frag_path, 'w', encoding='utf-8') as f:
            f.write(frag)
    frag = open(frag_path, encoding='utf-8').read()

    vert, vertex_elements, vertex_constants = vertex.make(glsl_rewrite.inputs(frag), skin)
    arm.utils.write_file_if_changed(os.path.join(build_shaders, name + '.vert.glsl'), vert, encoding='utf-8')

    constants, texture_units, samplers = fragment_bindings(frag, set(prepared.values), set(prepared.textures))
    mesh_context = {
        'name': GBUFFER_CONTEXT,
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'clockwise',
        'vertex_elements': vertex_elements,
        'color_attachments': ['RGBA64'] * glsl_rewrite.GBUFFER_IMAGES,
        'vertex_shader': name + '.vert',
        'fragment_shader': base + '.frag',
        # Not last: Iron's ArmPack reader peeks one byte past an array's length,
        # so an empty array at the very end of the file is read as null.
        'texture_units': texture_units,
        'constants': vertex_constants + constants,
    }
    shadow_vert, shadow_frag, shadow_elements, shadow_constants = vertex.make_shadow(skin)
    shadow_name = 'eevee_shadow_' + skin if skin else 'eevee_shadow'
    arm.utils.write_file_if_changed(os.path.join(build_shaders, shadow_name + '.vert.glsl'), shadow_vert, encoding='utf-8')
    arm.utils.write_file_if_changed(os.path.join(build_shaders, 'eevee_shadow.frag.glsl'), shadow_frag, encoding='utf-8')
    shadow_context = {
        'name': engine.shadow_context(),
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'none',  # Eevee casts from both sides unless use_backface_culling_shadow
        'vertex_elements': shadow_elements,
        'color_attachments': ['R32'],
        'vertex_shader': shadow_name + '.vert',
        'fragment_shader': 'eevee_shadow.frag',
        'texture_units': [],
        'constants': shadow_constants,
    }
    shader_data = {'name': name, 'contexts': [mesh_context, shadow_context]}
    shaders[name] = (shader_data, samplers)
    if not bpy.data.worlds['Arm'].arm_single_data_file:
        arm.utils.write_arm(os.path.join(build_shaders, name + '.arm'), {'shader_datas': [shader_data]})
    register_shader_data(build_shaders, name, shader_data)
    return shaders[name]


def fragment_bindings(frag: str, surface_inputs: set, image_nodes: set) -> tuple:
    """Shader data constants and texture units for a generated pixel shader, and
    the sampler of each image node (bound by every material to its own file).
    Surface inputs are set by every material (mx_graph.Prepared.values)."""
    constants = []
    texture_units = []
    samplers = {}
    for kind, name in glsl_rewrite.uniforms(frag):
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
    """Adds the shader data to the scene being exported (once per scene that uses it)."""
    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        from arm import exporter  # imported here: arm.exporter imports this module's caller
        output = exporter.current_output
        output.setdefault('shader_datas', [])
        if not any(sd['name'] == name for sd in output['shader_datas']):
            output['shader_datas'].append(shader_data)
    else:
        assets.add_shader_data(os.path.join(build_shaders, name + '.arm'))


def prune():
    """Deletes the material shaders no exported scene uses any more (after the
    scene export). Shader names change with the material and the renderer, and
    khamake compiles every shader in compiled/Shaders into the game, so an old
    one would ship with it. Linked scenes the exporter skipped (unchanged) keep
    theirs: their shader data is registered again (assets.shader_datas)."""
    names = set(context.current().shaders) | {os.path.basename(path).split('.')[0] for path in assets.shader_datas}
    used = {name for name in names if name.startswith(SHADER_PREFIX)}
    used |= {name[:len(SHADER_PREFIX) + HASH_LENGTH] for name in used}  # base: the shared pixel shader and its document
    files.prune(files.build_shaders(), set(),
                lambda file: file.startswith(SHADER_PREFIX) and file.split('.')[0] not in used)


def data_dir() -> str:
    return files.sdk_shaders('materialx')


def generation_key() -> str:
    """Changes whenever a generated shader could change: shader names include it."""
    ctx = context.current()
    if ctx.generation_key is None:
        digest = hashlib.sha1(mx_codegen.version().encode())
        here = os.path.dirname(os.path.abspath(__file__))
        paths = [os.path.join(data_dir(), n) for n in sorted(os.listdir(data_dir()))]
        paths.append(files.sdk_shaders('eevee_common.inc'))  # #included by arm_gbuffer.glsl
        paths += [os.path.join(here, n) for n in ('mx_codegen.py', 'mx_graph.py', 'glsl_rewrite.py', 'vertex.py')]
        for path in paths:
            with open(path, 'rb') as f:
                digest.update(f.read())
        ctx.generation_key = digest.hexdigest()
    return ctx.generation_key

