"""Material export for the Viewport renderer (called from material/make.py parse()).

Every material renders from its own node graph, as Blender exports it to
MaterialX (mx_export). Its shader is the material pass: it writes the surface
values to the material images, which the lighting pass reads (RenderPathViewportRaster).
Materials whose graphs differ only in their surface values share one shader
(mx_graph.prepare): those values are uniforms, set per material, and every
material binds its own textures. A material with AOV outputs has a pass per AOV
writing it (mx_export.aov_documents()), drawn after the material pass.
"""
import hashlib
import os

import bpy

import arm
import arm.viewport.context as context
import arm.assets as assets
import arm.viewport.raster.engine as engine
import arm.viewport.files as files
import arm.viewport.raster.glsl_rewrite as glsl_rewrite
import arm.viewport.raster.lighting as lighting
import arm.viewport.raster.mx_codegen as mx_codegen
import arm.viewport.mx_export as mx_export
import arm.viewport.raster.mx_graph as mx_graph
import arm.viewport.raster.vertex as vertex
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    context = arm.reload_module(context)
    engine = arm.reload_module(engine)
    files = arm.reload_module(files)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    lighting = arm.reload_module(lighting)
    mx_codegen = arm.reload_module(mx_codegen)
    mx_export = arm.reload_module(mx_export)
    mx_graph = arm.reload_module(mx_graph)
    vertex = arm.reload_module(vertex)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

SHADER_PREFIX = 'vpraster_mx_'
CULLING_SUFFIXES = {(False, False): '', (True, False): '_cullcamera',
                    (False, True): '_cullshadow', (True, True): '_cullboth'}
LATE_SUFFIX = '_late'  # shader data of Blended materials without alpha (their own passes)
DEPTH_ONLY_SHADER = 'vpraster_depth_only'  # pixel shader of the depth pre-pass (Transparency Overlap off)
# Pixel shader of a Blended material without alpha in the transparency image: the
# colour the lighting pass gave it (RasterTransparency binds vpraster_hdr), coverage 1
OPAQUE_COVERAGE_SHADER = 'vpraster_opaque_coverage'
OPAQUE_COVERAGE_SAMPLER = 'litImage'
OPAQUE_COVERAGE_SOURCE = ('#version 450\n'
                          'uniform sampler2D %s;\n'
                          'out vec4 fragColor;\n'
                          'void main() {\n'
                          '    fragColor = vec4(texelFetch(%s, ivec2(gl_FragCoord.xy), 0).rgb, 1.0);\n'
                          '}\n') % (OPAQUE_COVERAGE_SAMPLER, OPAQUE_COVERAGE_SAMPLER)
GBUFFER_CONTEXT = 'mesh'  # Iron's main object pass (tilesheets, GPU particles, debug draw hook on 'mesh')

# Uniforms of arm_gbuffer.glsl the engine fills: name -> (shader data type, link)
ENGINE_CONSTANTS = {'u_armFrame': ('float', '_vprasterFrame')}


def parse(material, mat_data, mat_users, mat_armusers):
    """Same contract as material/make.py parse(): returns (sd, rpasses, needs_sss)."""
    path = mx_export.document(material)
    if path is None:
        raise RuntimeError('Viewport renderer: material "%s" has no MaterialX document '
                           '(see the export warnings above)' % mx_export.display_name(material))
    prepared = mx_graph.prepare(path, mx_codegen.library(data_dir()), material.surface_render_method == 'BLENDED')
    if prepared.problem:
        # Other shader nodes are exported as BSDF graphs the material images do not hold yet
        armory_pbr = material.node_tree is not None and any(
            node.type == 'GROUP' and node.node_tree is not None and node.node_tree.name.startswith('Armory PBR')
            for node in material.node_tree.nodes)
        raise RuntimeError('Viewport renderer: material "%s": %s' % (mx_export.display_name(material),
                           'the Armory PBR node is not supported, use a Principled BSDF' if armory_pbr else
                           'only Principled BSDF, Diffuse BSDF and Emission surfaces are supported for now '
                           '(%s)' % prepared.problem))
    report = context.warn_once('material', mx_export.display_name(material))
    if report and prepared.dropped:
        log.warn('Viewport renderer: material "%s": not supported yet, rendered without: %s'
                 % (mx_export.display_name(material), ', '.join(prepared.dropped)))
    aovs = []  # (AOV name, type, prepared document)
    # Measured: Blended materials write no AOVs, even the ones drawn opaque (the
    # documents are per node tree, which a Blended material can share)
    written = [] if material.surface_render_method == 'BLENDED' else mx_export.aov_documents(material)
    for aov_name, kind, aov_path in written:
        aov = mx_graph.prepare(aov_path, mx_codegen.library(data_dir()))
        if aov.problem:
            if report:
                log.warn('Viewport renderer: material "%s": its AOV "%s" is not written (%s)'
                         % (mx_export.display_name(material), aov_name, aov.problem))
            continue
        aovs.append((aov_name, kind, aov))
    document = prepared.text + ''.join('\0%s\0%s\0%s' % (aov_name, kind, aov.text) for aov_name, kind, aov in aovs)
    base = SHADER_PREFIX + hashlib.sha1((document + generation_key()).encode()).hexdigest()[:12]
    skin = skinning(material, mat_users)
    program = base + '_' + skin if skin else base  # skinned meshes share the pixel shader, not the vertex shader
    culling =(material.use_backface_culling, material.use_backface_culling_shadow)
    # Blended without alpha shares its pixel shader with the same opaque surface, not
    # its passes (materials.write_shader): its shader data is named apart
    name = program + CULLING_SUFFIXES[culling] + (LATE_SUFFIX if prepared.opaque else '')
    shader_data, samplers = write_shader(name, program, base, prepared, skin, culling, aovs)

    textures = bind_textures(prepared, samplers[None])
    bind_constants = [constant(input_name, kind, value) for input_name, (kind, value) in sorted(prepared.values.items())]
    if prepared.blended:
        # RasterTransparency draws the object's passes in this order. Without alpha,
        # the material images after the AOVs, then its lit colour into the
        # transparency image. Transparency Overlap off: a depth pre-pass keeps only
        # its front-most surface. On, with both sides drawn: its back faces, then
        # its front faces over them.
        if prepared.opaque:
            passes = [engine.late_context(), engine.blend_opaque_context()]
        elif not material.use_transparency_overlap:
            passes = [engine.blend_depth_context(), engine.blend_context()]
        elif material.use_backface_culling:
            passes = [engine.blend_context()]
        else:
            passes = [engine.blend_back_context(), engine.blend_front_context()]
    else:
        passes = [GBUFFER_CONTEXT]
    for pass_name in passes:
        # The depth pre-pass and the coverage pass use none of the material's values
        depth_only = pass_name in (engine.blend_depth_context(), engine.blend_opaque_context())
        mat_data['contexts'].append({'name': pass_name, 'bind_constants': [] if depth_only else bind_constants,
                                     'bind_textures': [] if depth_only else textures, 'depth_read': False})
    # Its AOV outputs (RenderPathViewportRaster draws them after the material pass)
    for aov_name, kind, aov in aovs:
        passes.append(engine.aov_context(aov_name))
        mat_data['contexts'].append({'name': engine.aov_context(aov_name), 'depth_read': False,
                                     'bind_constants': [constant(n, k, v) for n, (k, v) in sorted(aov.values.items())],
                                     'bind_textures': bind_textures(aov, samplers[aov_name])})
    mat_data['contexts'].append({'name': engine.shadow_context(), 'bind_constants': [], 'bind_textures': []})

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        mat_data['shader'] = name
    else:
        ext = '' if wrd.arm_minimize else '.json'
        mat_data['shader'] = name + ext + '/' + name
    return shader_data, passes + [engine.shadow_context()], False


def bind_textures(prepared, samplers: dict) -> list:
    """The material's texture files for a pass's samplers; files are packed with
    compiled/Assets (mx_export.texture_folder())."""
    return [{'name': samplers[node], 'file': file, 'generate_mipmaps': True,
             'u_addressing': 'repeat', 'v_addressing': 'repeat',
             'min_filter': 'linear', 'mag_filter': 'linear', 'mipmap_filter': 'linear'}
            for node, file in prepared.textures.items()]


def constant(name: str, kind: str, value: str) -> dict:
    if kind == 'boolean':
        return {'name': name, 'boolValue': value == 'true'}
    numbers = [float(v) for v in value.replace(',', ' ').split()]
    if kind in ('color3', 'vector3'):
        return {'name': name, 'vec3Value': numbers[:3]}
    if kind == 'float':
        return {'name': name, 'floatValue': numbers[0]}
    raise RuntimeError('Viewport renderer: unsupported surface uniform %s (%s)' % (name, kind))


def skinning(material, mat_users) -> str:
    """vertex.LINEAR or vertex.DUAL for a material on skinned meshes (Blender's
    Armature modifier: dual quaternions with Preserve Volume), None otherwise."""
    modes = set()
    for obj in mat_users.get(material, []):
        if arm.utils.export_bone_data(obj):
            modifier = next((m for m in obj.modifiers if m.type == 'ARMATURE'), None)
            modes.add(vertex.DUAL if modifier is not None and modifier.use_deform_preserve_volume else vertex.LINEAR)
    if len(modes) > 1:
        raise RuntimeError('Viewport renderer: material "%s" is used by skinned meshes with and without the '
                           "Armature modifier's Preserve Volume; use one setting for all of them" % mx_export.display_name(material))
    return modes.pop() if modes else None


def fragment(base: str, prepared, rewrite) -> str:
    """The pixel shader `base` of a prepared document, generated once per build
    folder; `rewrite` turns MaterialX's colour output into the pass's outputs."""
    build_shaders = files.build_shaders()
    frag_path = os.path.join(build_shaders, base + '.frag.glsl')
    if not os.path.exists(frag_path):
        document_path = os.path.join(build_shaders, base + '.mtlx')
        with open(document_path, 'w', encoding='utf-8') as f:
            f.write(prepared.text)
        frag = mx_codegen.generate_fragment(data_dir(), document_path, base, mx_graph.SURFACE_NODE)
        frag = rewrite(glsl_rewrite.flatten_varyings(frag))
        with open(frag_path, 'w', encoding='utf-8') as f:
            f.write(frag)
    with open(frag_path, encoding='utf-8') as f:
        return f.read()


def write_shader(name: str, program: str, base: str, prepared, skin: str, culling: tuple, aovs: list) -> tuple:
    """Generates the shader for a canonical document (once per build folder) and
    registers its shader data `name`: the program (`base` pixel shader, `program`
    vertex shader) with the material's culling, (camera, shadow) back faces
    culled, and a pass per AOV output. Returns (shader data, samplers): {image
    node: sampler} of the material's pass (key None) and of each AOV's (its name)."""
    build_shaders = files.build_shaders()
    shaders = context.current().shaders
    if name in shaders and os.path.exists(os.path.join(build_shaders, base + '.frag.glsl')):
        register_shader_data(build_shaders, name, shaders[name][0])
        return shaders[name]

    # Blended with alpha: lit in its own shader and blended by its opacity. Every
    # other surface (Blended without alpha included) writes the material images
    translucent = prepared.blended and not prepared.opaque
    if translucent:
        frag = fragment(base, prepared,
                        lambda src: glsl_rewrite.blended_output(src, lighting.shading_library(), lighting.defines()))
    else:
        frag = fragment(base, prepared, glsl_rewrite.gbuffer_output)
    vert, vertex_elements, vertex_constants = vertex.make(glsl_rewrite.inputs(frag), skin)
    files.write_if_changed(os.path.join(build_shaders, program + '.vert.glsl'), vert)

    cull_camera, cull_shadow = culling
    constants, texture_units, material_samplers = fragment_bindings(frag, set(prepared.values), set(prepared.textures), translucent)
    samplers = {None: material_samplers}
    surface = {
        'vertex_elements': vertex_elements,
        'cull_mode': 'clockwise' if cull_camera else 'none',
        'vertex_shader': program + '.vert',
        'fragment_shader': base + '.frag',
        # Not last: Iron's ArmPack reader peeks one byte past an array's length,
        # so an empty array at the very end of the file is read as null.
        'texture_units': texture_units,
        'constants': vertex_constants + constants,
    }
    if prepared.opaque:
        # Blended without alpha (Eevee: opaque, in its forward pass). Into the material
        # images after the AOVs (RenderPathViewportRaster.LATE_CONTEXT), so the AOVs of
        # what is behind it stay, as in Eevee, then lit by the lighting pass with the
        # rest. Its pass into RasterTransparency's image only copies the lit colour
        # there with full coverage (Eevee's Transparent pass): no second lighting.
        files.write_if_changed(os.path.join(build_shaders, OPAQUE_COVERAGE_SHADER + '.frag.glsl'), OPAQUE_COVERAGE_SOURCE)
        surface_contexts = [
            dict(surface, name=engine.late_context(), depth_write=True, compare_mode='less',
                 color_attachments=['RGBA64'] * glsl_rewrite.GBUFFER_IMAGES),
            dict(surface, name=engine.blend_opaque_context(), depth_write=False, compare_mode='less_equal',
                 color_attachments=['RGBA64'], fragment_shader=OPAQUE_COVERAGE_SHADER + '.frag',
                 texture_units=[{'name': OPAQUE_COVERAGE_SAMPLER}], constants=vertex_constants),
        ]
    elif translucent:
        # Into RasterTransparency's image, cleared to transparent: the lit colour over
        # what is already there by the opacity, the coverage in alpha (Eevee's
        # Transparent pass). Less-or-equal: the depth pre-pass (Transparency Overlap
        # off) leaves the object's front-most depth.
        files.write_if_changed(os.path.join(build_shaders, DEPTH_ONLY_SHADER + '.frag.glsl'),
                               '#version 450\nvoid main() {}\n')
        blend = dict(surface, depth_write=False, compare_mode='less_equal', color_attachments=['RGBA64'],
                     blend_source='source_alpha', blend_destination='inverse_source_alpha', blend_operation='add',
                     alpha_blend_source='blend_one', alpha_blend_destination='inverse_source_alpha',
                     alpha_blend_operation='add')
        surface_contexts = [
            dict(blend, name=engine.blend_context()),
            dict(blend, name=engine.blend_back_context(), cull_mode='counter_clockwise'),
            dict(blend, name=engine.blend_front_context(), cull_mode='clockwise'),
            dict(surface, name=engine.blend_depth_context(), depth_write=True, compare_mode='less',
                 color_attachments=['RGBA64'], color_writes_red=[False], color_writes_green=[False],
                 color_writes_blue=[False], color_writes_alpha=[False],
                 fragment_shader=DEPTH_ONLY_SHADER + '.frag', texture_units=[], constants=vertex_constants),
        ]
    else:
        surface_contexts = [dict(surface, name=GBUFFER_CONTEXT, depth_write=True, compare_mode='less',
                                 color_attachments=['RGBA64'] * glsl_rewrite.GBUFFER_IMAGES)]
    for i, (aov_name, kind, aov) in enumerate(aovs):
        # Into the AOV's image, where the material pass left the surface in front:
        # its own document (mx_export.aov_material()), drawn again with the same
        # vertex positions, so less-or-equal passes exactly where it is visible
        aov_base, aov_program = '%s_aov%d' % (base, i), '%s_aov%d' % (program, i)
        aov_frag = fragment(aov_base, aov, lambda src, kind=kind: glsl_rewrite.aov_output(src, kind))
        aov_vert, aov_elements, aov_vertex_constants = vertex.make(glsl_rewrite.inputs(aov_frag), skin)
        files.write_if_changed(os.path.join(build_shaders, aov_program + '.vert.glsl'), aov_vert)
        aov_constants, aov_units, samplers[aov_name] = fragment_bindings(aov_frag, set(aov.values), set(aov.textures))
        surface_contexts.append(dict(surface, name=engine.aov_context(aov_name), depth_write=False,
                                     compare_mode='less_equal', color_attachments=['RGBA64'],
                                     vertex_elements=aov_elements, vertex_shader=aov_program + '.vert',
                                     fragment_shader=aov_base + '.frag', texture_units=aov_units,
                                     constants=aov_vertex_constants + aov_constants))
    shadow_vert, shadow_frag, shadow_elements, shadow_constants = vertex.make_shadow(skin)
    shadow_name = 'vpraster_shadow_' + skin if skin else 'vpraster_shadow'
    files.write_if_changed(os.path.join(build_shaders, shadow_name + '.vert.glsl'), shadow_vert)
    files.write_if_changed(os.path.join(build_shaders, 'vpraster_shadow.frag.glsl'), shadow_frag)
    shadow_context = {
        'name': engine.shadow_context(),
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'clockwise' if cull_shadow else 'none',
        'vertex_elements': shadow_elements,
        'color_attachments': ['R32'],
        'vertex_shader': shadow_name + '.vert',
        'fragment_shader': 'vpraster_shadow.frag',
        'texture_units': [],
        'constants': shadow_constants,
    }
    shader_data = {'name': name, 'contexts': surface_contexts + [shadow_context]}
    shaders[name] = (shader_data, samplers)
    register_shader_data(build_shaders, name, shader_data)
    return shaders[name]


def fragment_bindings(frag: str, surface_inputs: set, image_nodes: set, blended: bool = False) -> tuple:
    """Shader data constants and texture units for a generated pixel shader, and
    the sampler of each image node (bound by every material to its own file).
    Surface inputs are set by every material (mx_graph.Prepared.values). Blended
    materials also have the lighting pass's uniforms (lighting.py)."""
    constants = []
    texture_units = []
    samplers = {}
    for kind, name in glsl_rewrite.uniforms(frag):
        if name in surface_inputs:
            constants.append({'name': name, 'type': kind})
        elif name in ENGINE_CONSTANTS:
            ctype, link = ENGINE_CONSTANTS[name]
            constants.append({'name': name, 'type': ctype, 'link': link})
        elif blended and name in lighting.CONSTANTS:
            ctype, link = lighting.CONSTANTS[name]
            constants.append({'name': name, 'type': ctype, 'link': link})
        elif blended and name in lighting.TEXTURES:
            texture_units.append(dict({'name': name}, **lighting.TEXTURES[name]))
        elif kind == 'sampler2D' and name.split('_')[0] in image_nodes:
            texture_units.append({'name': name})
            samplers[name.split('_')[0]] = name
        else:
            raise RuntimeError('Viewport renderer: no binding for MaterialX uniform %s %s' % (kind, name))
    missing = image_nodes - set(samplers)
    if missing:
        raise RuntimeError('Viewport renderer: no sampler generated for image nodes %s' % sorted(missing))
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
    return files.sdk_shaders('materialx')


def generation_key() -> str:
    """Changes whenever a generated shader could change: shader names include it."""
    ctx = context.current()
    if ctx.generation_key is None:
        digest = hashlib.sha1(mx_codegen.version().encode())
        here = os.path.dirname(os.path.abspath(__file__))
        paths = [os.path.join(data_dir(), n) for n in sorted(os.listdir(data_dir()))]
        paths.append(files.sdk_shaders('vpraster_common.inc'))  # #included by arm_gbuffer.glsl
        paths += [files.sdk_shaders(n) for n in lighting.SHADING_SOURCES]  # in blended materials' shaders
        paths += [os.path.join(here, n) for n in ('mx_codegen.py', 'mx_graph.py', 'glsl_rewrite.py', 'vertex.py')]
        for path in paths:
            with open(path, 'rb') as f:
                digest.update(f.read())
        digest.update(repr(sorted(lighting.defines().items())).encode())  # sizes read from the engine
        ctx.generation_key = digest.hexdigest()
    return ctx.generation_key

