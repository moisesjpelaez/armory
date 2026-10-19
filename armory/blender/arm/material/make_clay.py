"""Temporary clay shading for the MaterialX renderer.

While the MaterialX render path is being brought up, all materials of a
scene are drawn with a fixed clay shading instead of their node trees.
This module is scaffolding and will be replaced once the MaterialX
translation provides the real material shaders.
"""

import bpy

import arm.assets as assets
import arm.material.mat_state as mat_state
import arm.material.make_attrib as make_attrib
import arm.material.make_finalize as make_finalize
import arm.material.make_inst as make_inst
import arm.material.make_skin as make_skin
import arm.material.make_morph_target as make_morph_target
from arm.material.shader import ShaderContext
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    mat_state = arm.reload_module(mat_state)
    make_attrib = arm.reload_module(make_attrib)
    make_finalize = arm.reload_module(make_finalize)
    make_inst = arm.reload_module(make_inst)
    make_skin = arm.reload_module(make_skin)
    make_morph_target = arm.reload_module(make_morph_target)
    arm.material.shader = arm.reload_module(arm.material.shader)
    from arm.material.shader import ShaderContext
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

# Fixed clay color and ambient fill factor
clay_color = (0.8, 0.8, 0.8)
ambient_factor = 0.15


def is_active() -> bool:
    """Whether the temporary clay shading is used instead of material shaders."""
    return arm.utils.get_rp().rp_renderer == 'MaterialX'


def make(context_id: str) -> ShaderContext:
    """Build the mesh context: fixed color lit by the sun, no material features."""
    wrd = bpy.data.worlds['Arm']

    con = {'name': context_id, 'depth_write': True, 'compare_mode': 'less', 'cull_mode': 'clockwise'}
    # Blending materials are drawn in a separate opaque pass (see RenderPathMaterialX)
    if mat_state.material.arm_blending:
        con['name'] = 'blend'
    # Drawn straight to the framebuffer
    con['color_attachments'] = ['RGBA32']
    con_mesh = mat_state.data.add_context(con)

    vert = con_mesh.make_vert()
    frag = con_mesh.make_frag()
    frag.ins = vert.outs

    vert.write_attrib('vec4 spos = vec4(pos.xyz, 1.0);')
    vert.add_include('compiled.inc')
    frag.add_include('compiled.inc')

    vert.add_uniform('mat3 N', '_normalMatrix')
    vert.add_out('vec3 wnormal')
    make_attrib.write_norpos(con_mesh, vert)
    frag.write_attrib('vec3 n = normalize(wnormal);')

    vert.add_uniform('mat4 WVP', '_worldViewProjectionMatrix')
    vert.write('gl_Position = WVP * spos;')

    frag.add_out('vec4 fragColor')
    frag.add_const('vec3', 'basecol', '(vec3({0}, {1}, {2}))'.format(*clay_color))
    frag.write('vec3 direct = vec3(0.0);')

    is_shadows = '_ShadowMap' in wrd.world_defs
    is_shadows_atlas = '_ShadowMapAtlas' in wrd.world_defs
    shadowmap_sun = 'shadowMap'
    if is_shadows_atlas:
        is_single_atlas = '_SingleAtlas' in wrd.world_defs
        shadowmap_sun = 'shadowMapAtlasSun' if not is_single_atlas else 'shadowMapAtlas'
        frag.add_uniform('vec2 smSizeUniform', '_shadowMapSize', included=True)

    if '_Sun' in wrd.world_defs:
        frag.add_uniform('vec3 sunCol', '_sunColor')
        frag.add_uniform('vec3 sunDir', '_sunDirection')
        frag.write('float svisibility = 1.0;')
        frag.write('float sdotNL = max(dot(n, sunDir), 0.0);')
        if is_shadows:
            vert.add_out('vec4 lightPosition')
            vert.add_uniform('mat4 LWVP', '_biasLightWorldViewProjectionMatrixSun')
            vert.write('lightPosition = LWVP * spos;')
            frag.add_uniform('bool receiveShadow')
            frag.add_uniform('sampler2DShadow {0}'.format(shadowmap_sun))
            frag.add_uniform('float shadowsBias', '_sunShadowsBias')
            frag.write('if (receiveShadow) {')
            if '_CSM' in wrd.world_defs:
                frag.add_include('std/shadows.glsl')
                frag.add_uniform('vec4 casData[shadowmapCascades * 4 + 4]', '_cascadeData', included=True)
                frag.add_uniform('vec3 eye', '_cameraPosition')
                frag.write('svisibility = shadowTestCascade({0}, eye, wposition + n * shadowsBias * 10, shadowsBias);'.format(shadowmap_sun))
            else:
                frag.write('if (lightPosition.w > 0.0) {')
                frag.write('    vec3 lPos = lightPosition.xyz / lightPosition.w;')
                if '_Legacy' in wrd.world_defs:
                    frag.write('    svisibility = float(texture({0}, vec2(lPos.xy)).r > lPos.z - shadowsBias);'.format(shadowmap_sun))
                else:
                    frag.write('    svisibility = texture({0}, vec3(lPos.xy, lPos.z - shadowsBias)).r;'.format(shadowmap_sun))
                frag.write('}')
            frag.write('}')
        frag.write('direct += basecol * sdotNL * sunCol * svisibility;')

    frag.write('vec3 clayColor = basecol * {0} + direct;'.format(ambient_factor))
    # The clay path draws directly to the framebuffer, so gamma is applied here
    frag.write('fragColor = vec4(pow(clayColor, vec3(1.0 / 2.2)), 1.0);')

    make_finalize.make(con_mesh)
    assets.vs_equal(con_mesh, assets.shader_cons['mesh_vert'])
    return con_mesh


def make_depth(context_id: str) -> ShaderContext:
    """Build the shadowmap context: opaque depth-only rendering."""
    vs = [{'name': 'pos', 'data': 'short4norm'}]
    con_depth = mat_state.data.add_context({ 'name': context_id, 'vertex_elements': vs, 'depth_write': True, 'compare_mode': 'less', 'cull_mode': 'clockwise', 'color_writes_red': [False], 'color_writes_green': [False], 'color_writes_blue': [False], 'color_writes_alpha': [False] })

    vert = con_depth.make_vert()
    con_depth.make_frag()

    vert.write_attrib('vec4 spos = vec4(pos.xyz, 1.0);')
    vert.add_include('compiled.inc')

    if con_depth.is_elem('morph'):
        make_morph_target.morph_pos(vert)

    if con_depth.is_elem('bone'):
        make_skin.skin_pos(vert)

    if con_depth.is_elem('ipos'):
        make_inst.inst_pos(con_depth, vert)

    vert.add_uniform('mat4 LWVP', '_lightWorldViewProjectionMatrix')
    vert.write('gl_Position = LWVP * spos;')

    make_finalize.make(con_depth)
    assets.vs_equal(con_depth, assets.shader_cons['depth_vert'])
    assets.fs_equal(con_depth, assets.shader_cons['depth_frag'])
    return con_depth
