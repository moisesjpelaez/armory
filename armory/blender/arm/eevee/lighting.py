"""Lighting pass of the Eevee renderer: one full-screen shader per project.

It lights every pixel of the material images (arm_gbuffer.glsl) the way Eevee
shades Blender's Principled BSDF, as measured. The shader is our own GLSL in
Shaders/eevee, assembled here after eevee_common.inc (noise, latlong mapping):
  eevee_specular.glsl   Eevee's reflectance table and lamp lobe
  eevee_lights.glsl     light data, lamps (arm_light) and soft shadows
  eevee_lighting.glsl   light scales, surface model, main()

RenderPathEevee draws it into eevee_hdr after the material pass.
"""
import os

import arm
import arm.assets as assets
import arm.eevee.engine as engine
import arm.eevee.files as files
import arm.eevee.glsl_rewrite as glsl_rewrite
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    engine = arm.reload_module(engine)
    files = arm.reload_module(files)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

NAME = 'eevee_lighting_pass'
SOURCES = ('eevee_specular.glsl', 'eevee_lights.glsl', 'eevee_lighting.glsl')


def defines() -> dict:
    """Sizes shared with the engine, read from its Haxe sources (engine.py)."""
    return {
        'MAX_LIGHT_SOURCES': engine.max_lights(),
        'ARM_LIGHT_VEC4S': engine.light_vec4s(),
        'ARM_MAX_SHADOW_VIEWS': engine.max_shadow_views(),
        'ARM_SHADOW_VIEW_VEC4S': engine.shadow_view_vec4s(),
        'ARM_SUN_CASCADES': engine.sun_cascades(),
    }

# Uniforms the engine fills: name -> (shader data type, link)
CONSTANTS = {
    'u_viewPosition': ('vec3', '_cameraPosition'),
    'u_numActiveLightSources': ('int', '_eeveeLightCount'),
    'u_lightPacked': ('floats', '_eeveeLights'),
    'u_envMatrix': ('mat4', '_eeveeEnvMatrix'),
    'u_envLightIntensity': ('float', '_eeveeEnvIntensity'),
    'u_envRadianceMips': ('int', '_eeveeEnvMips'),
    'u_armDirect': ('vec2', '_eeveeDirect'),
    'u_armIndirect': ('vec2', '_eeveeIndirect'),
    'u_armViewDir': ('vec4', '_eeveeViewDir'),
    'u_armShadows': ('floats', '_eeveeShadows'),
    'u_armShadowInfo': ('vec4', '_eeveeShadowInfo'),
    'invVP': ('mat4', '_inverseViewProjectionMatrix'),
}
TEXTURES = {
    'u_envRadiance': {'link': '_eeveeEnvRadiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                      'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'linear'},
    'u_envIrradiance': {'link': '_eeveeEnvIrradiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                        'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    'u_armDfg': {'link': '_eeveeDfg', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                 'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    'u_armLtc': {'link': '_eeveeLtc', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                 'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    # Depth atlas, compared by hand (bilinear-weighted) in eevee_lights.glsl
    'u_armShadowMap': {'link': '_eeveeShadowMap', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                       'filter_min': 'point', 'filter_mag': 'point', 'mipmap_filter': 'none'},
}
# Bound by RenderPathEevee (bindTarget)
TARGETS = ['gbuffer0', 'gbuffer1', 'gbuffer2', 'gbuffer3', 'gbuffer4', 'gbufferDepth']


def build():
    build_shaders = files.build_shaders()
    frag = source()
    files.write_if_changed(os.path.join(build_shaders, NAME + '.frag.glsl'), frag)

    context = {
        'name': NAME,
        'depth_write': False,
        'compare_mode': 'always',
        'cull_mode': 'none',
        'vertex_elements': [{'name': 'pos', 'data': 'float2'}],
        'color_attachments': ['RGBA64'],
        'vertex_shader': 'pass.vert',
        'fragment_shader': NAME + '.frag',
        'texture_units': [],
        'constants': [],
    }
    for kind, name in glsl_rewrite.uniforms(frag):
        if name in CONSTANTS:
            ctype, link = CONSTANTS[name]
            context['constants'].append({'name': name, 'type': ctype, 'link': link})
        elif name in TEXTURES:
            context['texture_units'].append(dict({'name': name}, **TEXTURES[name]))
        elif name in TARGETS:
            context['texture_units'].append({'name': name})
        else:
            raise RuntimeError('Eevee renderer: no binding for lighting pass uniform %s %s' % (kind, name))

    path = os.path.join(build_shaders, NAME + '.arm')
    arm.utils.write_arm(path, {'shader_datas': [{'name': NAME, 'contexts': [context]}]})
    assets.add_shader_data(path)


def source() -> str:
    folder = files.sdk_shaders()
    parts = ['#version 450', '#include "compiled.inc"']
    parts += ['#define %s %d' % item for item in defines().items()]
    # Inlined, not #included: khamake recompiles a shader only when its own text changes
    for name in ('eevee_common.inc',) + SOURCES:
        with open(os.path.join(folder, name), encoding='utf-8') as f:
            parts.append(f.read())
    return '\n'.join(parts)
