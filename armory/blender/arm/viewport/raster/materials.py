"""Material export for the Viewport renderer (called from material/make.py parse()).

Every material renders from its own node graph, as Blender exports it to
MaterialX (mx_export). Its shader is the material pass, which writes the surface
values into the material images. The lighting pass then reads those images
(RenderPathViewportRaster). Blended materials are drawn differently; see
SURFACE_CLASSES.

Materials whose graphs differ only in their surface values share one shader
(mx_graph.prepare). Those values are uniforms set per material, and every
material binds its own textures. A material with AOV outputs gets one extra pass
per AOV (mx_export.aov_documents()), drawn after the material pass.
"""
import hashlib
import os
from typing import Callable, NamedTuple

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
import arm.viewport.raster.state as state
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
    state = arm.reload_module(state)
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
# Pixel shader that draws a Blended material without alpha into the transparency
# image. It copies the colour the lighting pass gave the material (RasterTransparency
# binds vpraster_hdr) with a coverage of 1.
OPAQUE_COVERAGE_SHADER = 'vpraster_opaque_coverage'
OPAQUE_COVERAGE_SAMPLER = 'litImage'
OPAQUE_COVERAGE_SOURCE = ('#version 450\n'
                          'uniform sampler2D %s;\n'
                          'out vec4 fragColor;\n'
                          'void main() {\n'
                          '    fragColor = vec4(texelFetch(%s, ivec2(gl_FragCoord.xy), 0).rgb, 1.0);\n'
                          '}\n') % (OPAQUE_COVERAGE_SAMPLER, OPAQUE_COVERAGE_SAMPLER)
GBUFFER_CONTEXT = 'mesh'  # Iron's main object pass: tilesheets, GPU particles and debug drawing expect this name

# Uniforms of arm_gbuffer.glsl the engine fills: name -> (shader data type, link)
ENGINE_CONSTANTS = {'u_armFrame': ('float', '_vprasterFrame')}


# Eevee's surface classes. Eevee picks one from the material's Render Method and
# whether its surface has alpha, and each class draws its own passes. Everything a
# class decides is in its row of SURFACE_CLASSES. parse() picks the class, and
# write_shader() builds its contexts.
DEFERRED = 'deferred'              # Dithered: writes the material images, lit by the lighting pass
OPAQUE_FORWARD = 'opaque_forward'  # Blended without alpha: Eevee draws it opaque, in its forward pass
BLENDED = 'blended'                # Blended with alpha: lit in its own shader, blended over the image


class SurfaceClass(NamedTuple):
    aovs: bool          # writes the material's AOV outputs (as in Eevee, Blended materials write none)
    lit_here: bool      # lit in its own pixel shader (glsl_rewrite.blended_output), else writes the material images
    data_suffix: str    # shader data name suffix, where the same surface's passes differ by class
    passes: Callable    # (material) -> its passes (Iron contexts) in drawing order
    contexts: Callable  # (surface context, vertex constants, build folder) -> its shader data contexts


def surface_class(prepared) -> str:
    if not prepared.blended:
        return DEFERRED
    return OPAQUE_FORWARD if prepared.opaque else BLENDED


def deferred_passes(material) -> list:
    return [GBUFFER_CONTEXT]


def opaque_forward_passes(material) -> list:
    # Into the material images after the AOVs, then its lit colour into the transparency image
    return [engine.late_context(), engine.blend_opaque_context()]


def blended_passes(material) -> list:
    # RasterTransparency draws the passes in this order. With Transparency Overlap
    # off, a depth pre-pass keeps only the object's front-most surface. With it on
    # and both sides drawn (no backface culling), the back faces are drawn first,
    # then the front faces over them.
    if not material.use_transparency_overlap:
        return [engine.blend_depth_context(), engine.blend_context()]
    if material.use_backface_culling:
        return [engine.blend_context()]
    return [engine.blend_back_context(), engine.blend_front_context()]


def deferred_contexts(surface: dict, vertex_constants: list, build_shaders: str) -> list:
    return [dict(surface, name=GBUFFER_CONTEXT, depth_write=True, compare_mode='less',
                 color_attachments=['RGBA64'] * glsl_rewrite.GBUFFER_IMAGES)]


def opaque_forward_contexts(surface: dict, vertex_constants: list, build_shaders: str) -> list:
    # The first pass draws into the material images after the AOVs
    # (RenderPathViewportRaster.LATE_CONTEXT). The AOVs of what is behind the object
    # stay, as in Eevee, and the lighting pass lights it with the rest. The second
    # pass copies the lit colour into RasterTransparency's image with full coverage
    # (Eevee's Transparent pass), so the material is not lit twice.
    files.write_generated(os.path.join(build_shaders, OPAQUE_COVERAGE_SHADER + '.frag.glsl'), OPAQUE_COVERAGE_SOURCE)
    return [
        dict(surface, name=engine.late_context(), depth_write=True, compare_mode='less',
             color_attachments=['RGBA64'] * glsl_rewrite.GBUFFER_IMAGES),
        dict(surface, name=engine.blend_opaque_context(), depth_write=False, compare_mode='less_equal',
             color_attachments=['RGBA64'], fragment_shader=OPAQUE_COVERAGE_SHADER + '.frag',
             texture_units=[{'name': OPAQUE_COVERAGE_SAMPLER}], constants=vertex_constants),
    ]


def blended_contexts(surface: dict, vertex_constants: list, build_shaders: str) -> list:
    # Draws into RasterTransparency's image, which starts out transparent (Eevee's
    # Transparent pass). The lit colour is blended over what is there by the
    # opacity, and alpha holds the coverage. The depth test is less-or-equal because
    # the depth pre-pass (Transparency Overlap off) leaves the object's front-most
    # depth, which the colour pass must still pass.
    files.write_generated(os.path.join(build_shaders, DEPTH_ONLY_SHADER + '.frag.glsl'), '#version 450\nvoid main() {}\n')
    blend = dict(surface, depth_write=False, compare_mode='less_equal', color_attachments=['RGBA64'],
                 blend_source='source_alpha', blend_destination='inverse_source_alpha', blend_operation='add',
                 alpha_blend_source='blend_one', alpha_blend_destination='inverse_source_alpha',
                 alpha_blend_operation='add')
    return [
        dict(blend, name=engine.blend_context()),
        dict(blend, name=engine.blend_back_context(), cull_mode='counter_clockwise'),
        dict(blend, name=engine.blend_front_context(), cull_mode='clockwise'),
        dict(surface, name=engine.blend_depth_context(), depth_write=True, compare_mode='less',
             color_attachments=['RGBA64'], color_writes_red=[False], color_writes_green=[False],
             color_writes_blue=[False], color_writes_alpha=[False],
             fragment_shader=DEPTH_ONLY_SHADER + '.frag', texture_units=[], constants=vertex_constants),
    ]


SURFACE_CLASSES = {
    DEFERRED: SurfaceClass(aovs=True, lit_here=False, data_suffix='', passes=deferred_passes, contexts=deferred_contexts),
    # Same pixel shader as the same surface drawn deferred, but other passes: its shader data needs its own name
    OPAQUE_FORWARD: SurfaceClass(aovs=False, lit_here=False, data_suffix=LATE_SUFFIX, passes=opaque_forward_passes,
                                 contexts=opaque_forward_contexts),
    BLENDED: SurfaceClass(aovs=False, lit_here=True, data_suffix='', passes=blended_passes, contexts=blended_contexts),
}


def value_free_passes() -> tuple:
    """Passes that use none of the material's values: the depth pre-pass, the coverage copy."""
    return engine.blend_depth_context(), engine.blend_opaque_context()


def parse(material, mat_data, mat_users, mat_armusers):
    """Builds the material's shader and fills `mat_data` with its passes. Same
    contract as material/make.py parse(): returns (sd, rpasses, needs_sss), where
    needs_sss is always False."""
    path = mx_export.document(material)
    if path is None:
        raise RuntimeError('Viewport renderer: material "%s" has no MaterialX document '
                           '(see the export warnings above)' % mx_export.display_name(material))
    prepared = mx_graph.prepare(path, mx_codegen.library(data_dir()), material.surface_render_method == 'BLENDED')
    if prepared.problem:
        # Other shader nodes are exported as BSDF graphs, which the material images can't hold
        armory_pbr = material.node_tree is not None and any(
            node.type == 'GROUP' and node.node_tree is not None and node.node_tree.name.startswith('Armory PBR')
            for node in material.node_tree.nodes)
        raise RuntimeError('Viewport renderer: material "%s": %s' % (mx_export.display_name(material),
                           'the Armory PBR node is not supported, use a Principled BSDF' if armory_pbr else
                           'only Principled BSDF, Diffuse BSDF and Emission surfaces are supported '
                           '(%s)' % prepared.problem))
    report = context.warn_once('material', mx_export.display_name(material))
    if report and prepared.dropped:
        log.warn('Viewport renderer: material "%s": not supported, rendered without: %s'
                 % (mx_export.display_name(material), ', '.join(prepared.dropped)))
    kind = SURFACE_CLASSES[surface_class(prepared)]
    aovs = []  # (AOV name, type, prepared document)
    # AOV documents are stored per node tree, and a material of a class without AOVs
    # can share its tree with one that has them, so the class decides
    for aov_name, aov_type, aov_path in (mx_export.aov_documents(material) if kind.aovs else []):
        aov = mx_graph.prepare(aov_path, mx_codegen.library(data_dir()))
        if aov.problem:
            if report:
                log.warn('Viewport renderer: material "%s": its AOV "%s" is not written (%s)'
                         % (mx_export.display_name(material), aov_name, aov.problem))
            continue
        aovs.append((aov_name, aov_type, aov))
    document = prepared.text + ''.join('\0%s\0%s\0%s' % (aov_name, aov_type, aov.text) for aov_name, aov_type, aov in aovs)
    base = SHADER_PREFIX + hashlib.sha1((document + generation_key()).encode()).hexdigest()[:12]
    skin = skinning(material, mat_users)
    program = base + '_' + skin if skin else base  # skinned meshes share the pixel shader, not the vertex shader
    culling = (material.use_backface_culling, material.use_backface_culling_shadow)
    name = program + CULLING_SUFFIXES[culling] + kind.data_suffix
    shader_data, samplers = write_shader(name, program, base, prepared, kind, skin, culling, aovs)

    textures = bind_textures(prepared, samplers[None])
    bind_constants = [constant(input_name, value_kind, value)
                      for input_name, (value_kind, value) in sorted(prepared.values.items())]
    passes = kind.passes(material)
    for pass_name in passes:
        value_free = pass_name in value_free_passes()
        mat_data['contexts'].append({'name': pass_name, 'bind_constants': [] if value_free else bind_constants,
                                     'bind_textures': [] if value_free else textures, 'depth_read': False})
    # Its AOV outputs (RenderPathViewportRaster draws them after the material pass)
    for aov_name, aov_type, aov in aovs:
        passes.append(engine.aov_context(aov_name))
        mat_data['contexts'].append({'name': engine.aov_context(aov_name), 'depth_read': False,
                                     'bind_constants': [constant(n, k, v) for n, (k, v) in sorted(aov.values.items())],
                                     'bind_textures': bind_textures(aov, samplers[aov_name])})
    for shadow in (engine.shadow_context(), engine.shadow_perspective_context()):  # sun tiles, perspective tiles
        mat_data['contexts'].append({'name': shadow, 'bind_constants': [], 'bind_textures': []})

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        mat_data['shader'] = name
    else:
        ext = '' if wrd.arm_minimize else '.json'
        mat_data['shader'] = name + ext + '/' + name
    return shader_data, passes + [engine.shadow_context(), engine.shadow_perspective_context()], False


def bind_textures(prepared, samplers: dict) -> list:
    """The material's texture files, bound to a pass's samplers. The files are
    packed with compiled/Assets (mx_export.texture_folder())."""
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
    """vertex.LINEAR or vertex.DUAL for a material on skinned meshes, None
    otherwise. Like Blender's Armature modifier, Preserve Volume means dual
    quaternion skinning."""
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
    folder. `rewrite` turns MaterialX's colour output into the pass's outputs."""
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


def write_shader(name: str, program: str, base: str, prepared, kind: SurfaceClass, skin: str, culling: tuple,
                 aovs: list) -> tuple:
    """Generates the shader for a canonical document (once per build folder) and
    registers its shader data `name`. The shader data holds:
      - the passes of its surface class, with the `base` pixel shader and the
        `program` vertex shader
      - its culling: `culling` is (camera, shadow), whether back faces are culled
      - one pass per AOV output
      - the two shadow passes
    Returns (shader data, samplers). `samplers` maps None (the material's pass)
    and each AOV name to that pass's {image node: sampler}."""
    build_shaders = files.build_shaders()
    shaders = state.current().shaders
    if name in shaders and os.path.exists(os.path.join(build_shaders, base + '.frag.glsl')):
        register_shader_data(build_shaders, name, shaders[name][0])
        return shaders[name]

    if kind.lit_here:
        frag = fragment(base, prepared,
                        lambda src: glsl_rewrite.blended_output(src, lighting.shading_library(), lighting.defines()))
    else:
        frag = fragment(base, prepared, glsl_rewrite.gbuffer_output)
    vert, vertex_elements, vertex_constants = vertex.make(glsl_rewrite.inputs(frag), skin)
    files.write_generated(os.path.join(build_shaders, program + '.vert.glsl'), vert)

    cull_camera, cull_shadow = culling
    constants, texture_units, material_samplers = fragment_bindings(frag, set(prepared.values), set(prepared.textures),
                                                                    kind.lit_here)
    samplers = {None: material_samplers}
    surface = {
        'vertex_elements': vertex_elements,
        'cull_mode': 'clockwise' if cull_camera else 'none',
        'vertex_shader': program + '.vert',
        'fragment_shader': base + '.frag',
        # texture_units must not be the last key: Iron's ArmPack reader peeks one
        # byte past an array's end, so an empty array at the very end of the file
        # is read as null.
        'texture_units': texture_units,
        'constants': vertex_constants + constants,
    }
    surface_contexts = kind.contexts(surface, vertex_constants, build_shaders)
    for i, (aov_name, aov_type, aov) in enumerate(aovs):
        # Draws the AOV's own document (mx_export.aov_material()) into the AOV's
        # image. The mesh is drawn again with the same vertex positions, so the
        # less-or-equal depth test passes exactly where the material pass left
        # this surface in front.
        aov_base, aov_program = '%s_aov%d' % (base, i), '%s_aov%d' % (program, i)
        aov_frag = fragment(aov_base, aov, lambda src, aov_type=aov_type: glsl_rewrite.aov_output(src, aov_type))
        aov_vert, aov_elements, aov_vertex_constants = vertex.make(glsl_rewrite.inputs(aov_frag), skin)
        files.write_generated(os.path.join(build_shaders, aov_program + '.vert.glsl'), aov_vert)
        aov_constants, aov_units, samplers[aov_name] = fragment_bindings(aov_frag, set(aov.values), set(aov.textures))
        surface_contexts.append(dict(surface, name=engine.aov_context(aov_name), depth_write=False,
                                     compare_mode='less_equal', color_attachments=['RGBA64'],
                                     vertex_elements=aov_elements, vertex_shader=aov_program + '.vert',
                                     fragment_shader=aov_base + '.frag', texture_units=aov_units,
                                     constants=aov_vertex_constants + aov_constants))
    shadow_contexts = [shadow_context(build_shaders, skin, cull_shadow, perspective) for perspective in (False, True)]
    shader_data = {'name': name, 'contexts': surface_contexts + shadow_contexts}
    shaders[name] = (shader_data, samplers)
    register_shader_data(build_shaders, name, shader_data)
    return shaders[name]


def shadow_context(build_shaders: str, skin: str, cull: bool, perspective: bool) -> dict:
    """A mesh's pass into a shadow tile (RasterShadows). It writes depth only, and
    the lighting pass reads the atlas's depth buffer directly: copying the depth
    into a colour image would cost more. The R32 colour attachment is there only
    because a render target needs one; no colour is written. With `perspective`,
    the pass is for perspective views, whose casters write their linear depth
    themselves (vertex.make_shadow)."""
    vert, frag, elements, constants = vertex.make_shadow(skin, perspective)
    # The suffix is '_perspective', not '_linear' (for linear depth): 'linear' is a
    # skin type (vertex.LINEAR), so 'vpraster_shadow_linear' would name two programs
    program = ('vpraster_shadow_' + skin if skin else 'vpraster_shadow') + ('_perspective' if perspective else '')
    frag_name = (vertex.SHADOW_PERSPECTIVE_FRAG if perspective else vertex.SHADOW_FRAG)[:-len('.glsl')]
    files.write_generated(os.path.join(build_shaders, program + '.vert.glsl'), vert)
    files.write_generated(os.path.join(build_shaders, frag_name + '.glsl'), frag)
    return {
        'name': engine.shadow_perspective_context() if perspective else engine.shadow_context(),
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'clockwise' if cull else 'none',
        'vertex_elements': elements,
        'color_attachments': ['R32'],
        'color_writes_red': [False],
        'color_writes_green': [False],
        'color_writes_blue': [False],
        'color_writes_alpha': [False],
        'vertex_shader': program + '.vert',
        'fragment_shader': frag_name,
        'texture_units': [],
        'constants': constants,
    }


def fragment_bindings(frag: str, surface_inputs: set, image_nodes: set, blended: bool = False) -> tuple:
    """Shader data constants and texture units for a generated pixel shader, and
    the sampler of each image node (every material binds its own file to it).
    Every material sets the surface inputs (mx_graph.Prepared.values). Blended
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
    """Adds the shader data to the scene being exported (once per scene that uses it)."""
    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        from arm import exporter  # imported here: arm.exporter imports this module's caller (circular import)
        output = exporter.current_output
        output.setdefault('shader_datas', [])
        if not any(sd['name'] == name for sd in output['shader_datas']):
            output['shader_datas'].append(shader_data)
    else:
        path = os.path.join(build_shaders, name + '.arm')
        arm.utils.write_arm(path, {'shader_datas': [shader_data]})
        assets.add_shader_data(path)


def data_dir() -> str:
    return state.shaders('materialx')


def generation_key() -> str:
    """A hash of everything a generated shader depends on besides its document:
    MaterialX's version, the shader sources and these Python modules. Shader names
    include it, so any change gives new shaders."""
    ctx = state.current()
    if ctx.generation_key is None:
        digest = hashlib.sha1(mx_codegen.version().encode())
        here = os.path.dirname(os.path.abspath(__file__))
        paths = [os.path.join(data_dir(), n) for n in sorted(os.listdir(data_dir()))]
        paths.append(state.shaders('vpraster_common.inc'))  # #included by arm_gbuffer.glsl
        paths += [state.shaders(n) for n in lighting.SHADING_SOURCES]  # in blended materials' shaders
        # Vertex and shadow programs (vertex.py), and the Python that writes the shaders and shader data
        paths += [state.shaders(n) for n in ('vpraster_mesh.vert.glsl', 'vpraster_skin.inc',
                                                 'vpraster_shadow.vert.glsl', vertex.SHADOW_FRAG,
                                                 vertex.SHADOW_PERSPECTIVE_FRAG)]
        paths += [os.path.join(here, n) for n in ('mx_codegen.py', 'mx_graph.py', 'glsl_rewrite.py', 'vertex.py', 'materials.py', 'state.py',
                                                    'lighting.py')]  # lighting.py: blended materials' bindings
        for path in paths:
            with open(path, 'rb') as f:
                digest.update(f.read())
        digest.update(repr(sorted(lighting.defines().items())).encode())  # sizes read from the engine
        ctx.generation_key = digest.hexdigest()
    return ctx.generation_key

