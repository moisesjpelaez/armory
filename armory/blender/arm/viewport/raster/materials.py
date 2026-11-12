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
import arm.viewport.glsl as glsl
import arm.viewport.raster.glsl_rewrite as glsl_rewrite
import arm.viewport.raster.lighting as lighting
import arm.viewport.raster.mx_codegen as mx_codegen
import arm.viewport.mx_export as mx_export
import arm.viewport.mx_report as mx_report
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
    glsl = arm.reload_module(glsl)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    lighting = arm.reload_module(lighting)
    mx_codegen = arm.reload_module(mx_codegen)
    mx_export = arm.reload_module(mx_export)
    mx_report = arm.reload_module(mx_report)
    mx_graph = arm.reload_module(mx_graph)
    state = arm.reload_module(state)
    vertex = arm.reload_module(vertex)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

SHADER_PREFIX = 'vpraster_mx_'  # shader base name: SHADER_PREFIX + the short hash of the document (files.short_hash())
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


# --- Surface classes ------------------------------------------------------------
#
# Eevee picks a surface class from the material's Render Method and whether its
# surface has alpha (mx_graph.surface_class()), and each class draws its own
# passes. Everything a class decides is in its row of SURFACE_CLASSES.

class SurfacePass(NamedTuple):
    """One pass of a surface class: an Iron context of the shader data, which the
    materials that draw it bind."""
    name: Callable            # () -> the context's name
    context: Callable         # (name, surface context, vertex constants) -> its shader data context
    uses_values: bool = True  # whether it reads the material's values and textures


class SurfaceClass(NamedTuple):
    aovs: bool          # writes the material's AOV outputs (as in Eevee, Blended materials write none)
    lit_here: bool      # lit in its own pixel shader (glsl_rewrite.blended_output), else writes the material images
    data_suffix: str    # shader data name suffix, where the same surface's passes differ by class
    passes: tuple       # every SurfacePass of the class, in the shader data's order
    drawn: Callable     # (material) -> the passes that material draws, in drawing order


def material_images_context(name: str, surface: dict, vertex_constants: list) -> dict:
    """Writes the surface values into the material images."""
    return dict(surface, name=name, depth_write=True, compare_mode='less',
                color_attachments=['RGBA64'] * glsl_rewrite.GBUFFER_IMAGES)


def opaque_coverage_context(name: str, surface: dict, vertex_constants: list) -> dict:
    """Copies the lit colour into RasterTransparency's image with full coverage
    (Eevee's Transparent pass), so the material is not lit twice."""
    files.write_generated(os.path.join(files.build_shaders(), OPAQUE_COVERAGE_SHADER + '.frag.glsl'),
                          OPAQUE_COVERAGE_SOURCE)
    return dict(surface, name=name, depth_write=False, compare_mode='less_equal',
                color_attachments=['RGBA64'], fragment_shader=OPAQUE_COVERAGE_SHADER + '.frag',
                texture_units=[{'name': OPAQUE_COVERAGE_SAMPLER}], constants=vertex_constants)


def blend_state(surface: dict) -> dict:
    """The surface context, drawing into RasterTransparency's image, which starts
    out transparent (Eevee's Transparent pass). The lit colour is blended over
    what is there by the opacity, and alpha holds the coverage. The depth test is
    less-or-equal because the depth pre-pass (Transparency Overlap off) leaves the
    object's front-most depth, which the colour pass must still pass."""
    return dict(surface, depth_write=False, compare_mode='less_equal', color_attachments=['RGBA64'],
                blend_source='source_alpha', blend_destination='inverse_source_alpha', blend_operation='add',
                alpha_blend_source='blend_one', alpha_blend_destination='inverse_source_alpha',
                alpha_blend_operation='add')


def blend_context(name: str, surface: dict, vertex_constants: list) -> dict:
    return dict(blend_state(surface), name=name)


def blend_back_context(name: str, surface: dict, vertex_constants: list) -> dict:
    return dict(blend_state(surface), name=name, cull_mode='counter_clockwise')


def blend_front_context(name: str, surface: dict, vertex_constants: list) -> dict:
    return dict(blend_state(surface), name=name, cull_mode='clockwise')


def blend_depth_context(name: str, surface: dict, vertex_constants: list) -> dict:
    """The depth pre-pass of a Blended material: depth only, no colour."""
    files.write_generated(os.path.join(files.build_shaders(), DEPTH_ONLY_SHADER + '.frag.glsl'),
                          '#version 450\nvoid main() {}\n')
    return dict(surface, name=name, depth_write=True, compare_mode='less',
                color_attachments=['RGBA64'], color_writes_red=[False], color_writes_green=[False],
                color_writes_blue=[False], color_writes_alpha=[False],
                fragment_shader=DEPTH_ONLY_SHADER + '.frag', texture_units=[], constants=vertex_constants)


GBUFFER_PASS = SurfacePass(lambda: GBUFFER_CONTEXT, material_images_context)
# Draws into the material images after the AOVs (RenderPathViewportRaster.LATE_CONTEXT).
# The AOVs of what is behind the object stay, as in Eevee, and the lighting pass
# lights it with the rest.
LATE_PASS = SurfacePass(engine.late_context, material_images_context)
OPAQUE_COVERAGE_PASS = SurfacePass(engine.blend_opaque_context, opaque_coverage_context, uses_values=False)
BLEND_PASS = SurfacePass(engine.blend_context, blend_context)
BLEND_BACK_PASS = SurfacePass(engine.blend_back_context, blend_back_context)
BLEND_FRONT_PASS = SurfacePass(engine.blend_front_context, blend_front_context)
BLEND_DEPTH_PASS = SurfacePass(engine.blend_depth_context, blend_depth_context, uses_values=False)


def deferred_drawn(material) -> list:
    return [GBUFFER_PASS]


def opaque_forward_drawn(material) -> list:
    # Into the material images after the AOVs, then its lit colour into the transparency image
    return [LATE_PASS, OPAQUE_COVERAGE_PASS]


def blended_drawn(material) -> list:
    # RasterTransparency draws the passes in this order. With Transparency Overlap
    # off, a depth pre-pass keeps only the object's front-most surface. With it on
    # and both sides drawn (no backface culling), the back faces are drawn first,
    # then the front faces over them.
    if not material.use_transparency_overlap:
        return [BLEND_DEPTH_PASS, BLEND_PASS]
    if material.use_backface_culling:
        return [BLEND_PASS]
    return [BLEND_BACK_PASS, BLEND_FRONT_PASS]


SURFACE_CLASSES = {
    mx_graph.DEFERRED: SurfaceClass(aovs=True, lit_here=False, data_suffix='',
                                    passes=(GBUFFER_PASS,), drawn=deferred_drawn),
    # Same pixel shader as the same surface drawn deferred, but other passes: its shader data needs its own name
    mx_graph.OPAQUE_FORWARD: SurfaceClass(aovs=False, lit_here=False, data_suffix=LATE_SUFFIX,
                                          passes=(LATE_PASS, OPAQUE_COVERAGE_PASS), drawn=opaque_forward_drawn),
    mx_graph.BLENDED: SurfaceClass(aovs=False, lit_here=True, data_suffix='',
                                   passes=(BLEND_PASS, BLEND_BACK_PASS, BLEND_FRONT_PASS, BLEND_DEPTH_PASS),
                                   drawn=blended_drawn),
}


def drawn_passes(surface_class: SurfaceClass, material) -> list:
    """The passes of its class that the material draws, in drawing order."""
    drawn = surface_class.drawn(material)
    if any(surface_pass not in surface_class.passes for surface_pass in drawn):
        raise RuntimeError('Viewport renderer: a surface class draws a pass that is not in its shader data')
    return drawn


# --- A material's shader --------------------------------------------------------

class Aov(NamedTuple):
    """One AOV output of a material."""
    name: str
    type: str         # 'COLOR' or 'VALUE'
    prepared: object  # its document, prepared (mx_graph.Prepared)


class Shader(NamedTuple):
    """The names and options of a material's shader (shader_for())."""
    name: str                    # shader data: `program` + its culling + its class's suffix
    program: str                 # vertex shader: `base` + its skinning
    base: str                    # pixel shader: SHADER_PREFIX + the short hash of its documents
    surface_class: SurfaceClass
    skin: str                    # vertex.LINEAR, vertex.DUAL or None
    cull_camera: bool            # whether back faces are culled in the camera's passes
    cull_shadow: bool            # whether back faces are culled in the shadow passes


class Samplers(NamedTuple):
    """The sampler of each image node, {image node: sampler}, in each pass of a shader."""
    material: dict  # in the material's own passes
    aovs: dict      # AOV name -> in that AOV's pass


def parse(material, mat_data, mat_users, mat_armusers):
    """Builds the material's shader and fills `mat_data` with its passes. Same
    contract as material/make.py parse(): returns (sd, rpasses, needs_sss), where
    needs_sss is always False."""
    prepared = prepare_surface(material)
    report = context.warn_once('material', mx_report.display_name(material))
    if report and prepared.dropped:
        log.warn('Viewport renderer: material "%s": not supported, rendered without: %s'
                 % (mx_report.display_name(material), ', '.join(prepared.dropped)))
    surface_class = SURFACE_CLASSES[prepared.surface_class]
    aovs = prepare_aovs(material, surface_class, report)
    shader = shader_for(material, mat_users, prepared, surface_class, aovs)
    shader_data, samplers = write_shader(shader, prepared, aovs)
    passes = bind_passes(mat_data, material, surface_class, prepared, aovs, samplers)
    mat_data['shader'] = shader_reference(shader.name)
    return shader_data, passes, False


def prepare_surface(material):
    """The material's document, prepared for the material pass (mx_graph.Prepared).
    Fails the build if the material has no document or a surface that cannot be
    rendered."""
    path = mx_export.document(material)
    if path is None:
        raise RuntimeError('Viewport renderer: material "%s" has no MaterialX document '
                           '(see the export warnings above)' % mx_report.display_name(material))
    prepared = mx_graph.prepare(path, mx_codegen.library(data_dir()), material.surface_render_method == 'BLENDED')
    if prepared.problem:
        # Other shader nodes are exported as BSDF graphs, which the material images can't hold
        armory_pbr = material.node_tree is not None and any(
            node.type == 'GROUP' and node.node_tree is not None and node.node_tree.name.startswith('Armory PBR')
            for node in material.node_tree.nodes)
        raise RuntimeError('Viewport renderer: material "%s": %s' % (mx_report.display_name(material),
                           'the Armory PBR node is not supported, use a Principled BSDF' if armory_pbr else
                           'only Principled BSDF, Diffuse BSDF and Emission surfaces are supported '
                           '(%s)' % prepared.problem))
    return prepared


def prepare_aovs(material, surface_class: SurfaceClass, report: bool) -> list:
    """The material's AOV outputs that can be written, as Aovs. `report` is whether
    to warn about the others."""
    aovs = []
    # AOV documents are stored per node tree, and a material of a class without AOVs
    # can share its tree with one that has them, so the class decides
    for aov_name, aov_type, aov_path in (mx_export.aov_documents(material) if surface_class.aovs else []):
        aov = mx_graph.prepare(aov_path, mx_codegen.library(data_dir()))
        if aov.problem:
            if report:
                log.warn('Viewport renderer: material "%s": its AOV "%s" is not written (%s)'
                         % (mx_report.display_name(material), aov_name, aov.problem))
            continue
        aovs.append(Aov(aov_name, aov_type, aov))
    return aovs


def shader_for(material, mat_users, prepared, surface_class: SurfaceClass, aovs: list) -> Shader:
    """Names the material's shader after everything it is made from: its documents,
    its skinning, its culling and its surface class."""
    document = prepared.text + ''.join('\0%s\0%s\0%s' % (aov.name, aov.type, aov.prepared.text) for aov in aovs)
    base = SHADER_PREFIX + files.short_hash(document + generation_key())
    skin = skinning(material, mat_users)
    program = base + '_' + skin if skin else base  # skinned meshes share the pixel shader, not the vertex shader
    culling = (material.use_backface_culling, material.use_backface_culling_shadow)
    name = program + CULLING_SUFFIXES[culling] + surface_class.data_suffix
    return Shader(name, program, base, surface_class, skin, *culling)


def bind_passes(mat_data: dict, material, surface_class: SurfaceClass, prepared, aovs: list,
                samplers: Samplers) -> list:
    """Adds the material's passes to `mat_data`, each with the values and textures
    the material binds in it. Returns the passes' names."""
    textures = bind_textures(prepared, samplers.material)
    bind_constants = constants_of(prepared)
    passes = []
    for surface_pass in drawn_passes(surface_class, material):
        passes.append(surface_pass.name())
        mat_data['contexts'].append({'name': surface_pass.name(),
                                     'bind_constants': bind_constants if surface_pass.uses_values else [],
                                     'bind_textures': textures if surface_pass.uses_values else [],
                                     'depth_read': False})
    # Its AOV outputs (RenderPathViewportRaster draws them after the material pass)
    for aov in aovs:
        passes.append(engine.aov_context(aov.name))
        mat_data['contexts'].append({'name': engine.aov_context(aov.name), 'depth_read': False,
                                     'bind_constants': constants_of(aov.prepared),
                                     'bind_textures': bind_textures(aov.prepared, samplers.aovs[aov.name])})
    for shadow in (engine.shadow_context(), engine.shadow_perspective_context()):  # sun tiles, perspective tiles
        passes.append(shadow)
        mat_data['contexts'].append({'name': shadow, 'bind_constants': [], 'bind_textures': []})
    return passes


def shader_reference(name: str) -> str:
    """How a material names its shader data: by name in the scene's single data
    file, or by file and name."""
    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        return name
    ext = '' if wrd.arm_minimize else '.json'
    return name + ext + '/' + name


def constants_of(prepared) -> list:
    """The material's values for its document's surface inputs."""
    return [constant(input_name, mx_type, value) for input_name, (mx_type, value) in sorted(prepared.values.items())]


def bind_textures(prepared, samplers: dict) -> list:
    """The material's texture files, bound to a pass's samplers. The files are
    packed with compiled/Assets (mx_export.texture_folder())."""
    return [{'name': samplers[node], 'file': file, 'generate_mipmaps': True,
             'u_addressing': 'repeat', 'v_addressing': 'repeat',
             'min_filter': 'linear', 'mag_filter': 'linear', 'mipmap_filter': 'linear'}
            for node, file in prepared.textures.items()]


def constant(name: str, mx_type: str, value: str) -> dict:
    """A material's value for the surface input `name`, of MaterialX type `mx_type`."""
    if mx_type == 'boolean':
        return {'name': name, 'boolValue': value == 'true'}
    numbers = [float(v) for v in value.replace(',', ' ').split()]
    if mx_type in ('color3', 'vector3'):
        return {'name': name, 'vec3Value': numbers[:3]}
    if mx_type == 'float':
        return {'name': name, 'floatValue': numbers[0]}
    raise RuntimeError('Viewport renderer: unsupported surface uniform %s (%s)' % (name, mx_type))


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
                           "Armature modifier's Preserve Volume; use one setting for all of them" % mx_report.display_name(material))
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


def write_shader(shader: Shader, prepared, aovs: list) -> tuple:
    """Generates the shader for a canonical document (once per build folder) and
    registers its shader data. The shader data holds:
      - the passes of its surface class
      - one pass per AOV output
      - the two shadow passes
    Returns (shader data, Samplers)."""
    build_shaders = files.build_shaders()
    shaders = state.current().shaders
    if shader.name in shaders and os.path.exists(os.path.join(build_shaders, shader.base + '.frag.glsl')):
        register_shader_data(build_shaders, shader.name, shaders[shader.name][0])
        return shaders[shader.name]

    surface, vertex_constants, material_samplers = surface_context(shader, prepared)
    contexts = [surface_pass.context(surface_pass.name(), surface, vertex_constants)
                for surface_pass in shader.surface_class.passes]
    samplers = Samplers(material_samplers, {})
    for i, aov in enumerate(aovs):
        aov_pass, samplers.aovs[aov.name] = aov_context(shader, surface, i, aov)
        contexts.append(aov_pass)
    contexts += [shadow_context(build_shaders, shader.skin, shader.cull_shadow, perspective)
                 for perspective in (False, True)]
    shader_data = {'name': shader.name, 'contexts': contexts}
    shaders[shader.name] = (shader_data, samplers)
    if not bpy.data.worlds['Arm'].arm_single_data_file:
        arm.utils.write_arm(os.path.join(build_shaders, shader.name + '.arm'), {'shader_datas': [shader_data]})
    register_shader_data(build_shaders, shader.name, shader_data)
    return shaders[shader.name]


def surface_context(shader: Shader, prepared) -> tuple:
    """Writes the material's pixel and vertex shaders. Returns what its class's
    passes share: (the context they start from, the vertex shader's constants,
    {image node: sampler})."""
    if shader.surface_class.lit_here:
        frag = fragment(shader.base, prepared,
                        lambda src: glsl_rewrite.blended_output(src, lighting.shading_library(), lighting.defines()))
    else:
        frag = fragment(shader.base, prepared, glsl_rewrite.gbuffer_output)
    vert, vertex_elements, vertex_constants = vertex.make(glsl.inputs(frag), shader.skin)
    files.write_generated(os.path.join(files.build_shaders(), shader.program + '.vert.glsl'), vert)

    constants, texture_units, samplers = fragment_bindings(frag, set(prepared.values), set(prepared.textures),
                                                           shader.surface_class.lit_here)
    surface = {
        'vertex_elements': vertex_elements,
        'cull_mode': 'clockwise' if shader.cull_camera else 'none',
        'vertex_shader': shader.program + '.vert',
        'fragment_shader': shader.base + '.frag',
        # texture_units must not be the last key: Iron's ArmPack reader peeks one
        # byte past an array's end, so an empty array at the very end of the file
        # is read as null.
        'texture_units': texture_units,
        'constants': vertex_constants + constants,
    }
    return surface, vertex_constants, samplers


def aov_context(shader: Shader, surface: dict, index: int, aov: Aov) -> tuple:
    """Writes the shaders of the material's AOV output number `index`. Returns
    (its shader data context, {image node: sampler}). The pass draws the AOV's own
    document (mx_aov.aov_material()) into the AOV's image. The mesh is drawn again
    with the same vertex positions, so the less-or-equal depth test passes exactly
    where the material pass left this surface in front."""
    base, program = '%s_aov%d' % (shader.base, index), '%s_aov%d' % (shader.program, index)
    frag = fragment(base, aov.prepared, lambda src: glsl_rewrite.aov_output(src, aov.type))
    vert, elements, vertex_constants = vertex.make(glsl.inputs(frag), shader.skin)
    files.write_generated(os.path.join(files.build_shaders(), program + '.vert.glsl'), vert)
    constants, units, samplers = fragment_bindings(frag, set(aov.prepared.values), set(aov.prepared.textures))
    aov_pass = dict(surface, name=engine.aov_context(aov.name), depth_write=False,
                    compare_mode='less_equal', color_attachments=['RGBA64'],
                    vertex_elements=elements, vertex_shader=program + '.vert',
                    fragment_shader=base + '.frag', texture_units=units,
                    constants=vertex_constants + constants)
    return aov_pass, samplers


def shadow_context(build_shaders: str, skin: str, cull: bool, perspective: bool) -> dict:
    """A mesh's pass into a shadow tile (RasterShadowCasters). It writes depth only, and
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
    for glsl_type, name in glsl.uniforms(frag):
        if name in surface_inputs:
            constants.append({'name': name, 'type': glsl_type})
        elif name in ENGINE_CONSTANTS:
            ctype, link = ENGINE_CONSTANTS[name]
            constants.append({'name': name, 'type': ctype, 'link': link})
        elif blended and name in lighting.CONSTANTS:
            ctype, link = lighting.CONSTANTS[name]
            constants.append({'name': name, 'type': ctype, 'link': link})
        elif blended and name in lighting.TEXTURES:
            texture_units.append(dict({'name': name}, **lighting.TEXTURES[name]))
        elif glsl_type == 'sampler2D' and name.split('_')[0] in image_nodes:
            texture_units.append({'name': name})
            samplers[name.split('_')[0]] = name
        else:
            raise RuntimeError('Viewport renderer: no binding for MaterialX uniform %s %s' % (glsl_type, name))
    missing = image_nodes - set(samplers)
    if missing:
        raise RuntimeError('Viewport renderer: no sampler generated for image nodes %s' % sorted(missing))
    return constants, texture_units, samplers


def register_shader_data(build_shaders: str, name: str, shader_data: dict):
    """Adds the shader data to the scene being exported (once per scene that uses it)."""
    assets.add_shader_data_name(name)  # kept by prune(); replayed for scenes the export cache skips
    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        from arm import exporter  # imported here: arm.exporter imports this module's caller (circular import)
        output = exporter.current_output
        output.setdefault('shader_datas', [])
        if not any(sd['name'] == name for sd in output['shader_datas']):
            output['shader_datas'].append(shader_data)
    else:
        assets.add_shader_data(os.path.join(build_shaders, name + '.arm'))


def prune():
    """Deletes the material shaders no exported scene uses any more. Runs after
    the scene export. Shader names change with the material and the renderer, and
    khamake compiles every shader in compiled/Shaders into the game, so an old one
    would ship with it. Unchanged linked scenes that the exporter skipped keep
    their shaders: the export cache replays their names (assets.shader_data_names),
    with or without a single data file."""
    names = set(state.current().shaders) | set(assets.shader_data_names)
    # Every file of a shader starts with its base name (SHADER_PREFIX + short hash):
    # pixel and vertex shaders, AOV passes, documents and shader data
    length = len(SHADER_PREFIX) + files.HASH_LENGTH
    used = {name[:length] for name in names if name.startswith(SHADER_PREFIX)}
    files.prune(files.build_shaders(), set(), lambda file: file.startswith(SHADER_PREFIX) and file[:length] not in used)


def data_dir() -> str:
    return state.shaders('materialx')


def generation_key() -> str:
    """A hash of everything a generated shader depends on besides its document:
    MaterialX's version, the shader sources and these Python modules. Shader names
    include it, so any change gives new shaders."""
    ctx = state.current()
    if ctx.generation_key is None:
        digest = hashlib.sha1(mx_codegen.version().encode())
        # Every shader source of the renderer and all of its Python: nothing a
        # material's shaders include or are written by can be left out
        viewport = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        paths = files.source_files(state.shaders(), ('.glsl', '.inc', '.mtlx'))
        paths += files.source_files(viewport, ('.py',))
        digest.update(files.source_key(*paths).encode())
        digest.update(repr(sorted(lighting.defines().items())).encode())  # sizes read from the engine
        ctx.generation_key = digest.hexdigest()
    return ctx.generation_key

