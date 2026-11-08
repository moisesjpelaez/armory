"""Lighting pass of the Viewport renderer: one full-screen shader per project.

It lights every pixel of the material images (arm_gbuffer.glsl) the way Eevee
shades Blender's Principled BSDF, as measured. The shader is our own GLSL in
Shaders/vpraster, assembled here after vpraster_common.inc (noise, latlong mapping):
  vpraster_specular.glsl   Eevee's reflectance table and lamp lobe
  vpraster_lights.glsl     light data, lamps (arm_light) and soft shadows
  vpraster_shading.glsl    light scales, surface model: arm_shade()
  vpraster_lighting.glsl   main(): reads the material images, calls arm_shade()
Blended materials shade with the same files but their own main()
(shading_library(), used by materials.py).

RenderPathViewportRaster draws it into vpraster_hdr after the material pass.

Four versions are built (VARIANTS), with code the frame doesn't need compiled out:
  ARM_POINT_LAMPS        every lamp is a point: no lamp outlines (RasterLights.outlines)
  ARM_SUN_SHADOWS_ONLY   no spot, point or area light casts a shadow
                         (RasterLights.localShadows): no perspective shadow views
RenderPathViewportRaster.lightingPass() draws the one each frame needs, loading
each the first time: the same image from a shorter shader. Code that never runs
still slowed the shader (Larimar on an AMD integrated GPU: outlines 0.7 ms,
perspective shadows 1.5 ms). Blended materials keep all of it (shading_library()).
"""
import os

import arm
import arm.assets as assets
import arm.viewport.raster.engine as engine
import arm.viewport.files as files
import arm.viewport.raster.glsl_rewrite as glsl_rewrite
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    engine = arm.reload_module(engine)
    files = arm.reload_module(files)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

NAME = 'vpraster_lighting_pass'
# Shader name -> defines, the same names as RenderPathViewportRaster.LIGHTING
VARIANTS = {
    NAME: (),
    'vpraster_lighting_points': ('ARM_POINT_LAMPS',),
    'vpraster_lighting_sun': ('ARM_SUN_SHADOWS_ONLY',),
    'vpraster_lighting_points_sun': ('ARM_POINT_LAMPS', 'ARM_SUN_SHADOWS_ONLY'),
}
SHADING_SOURCES = ('vpraster_specular.glsl', 'vpraster_lights.glsl', 'vpraster_shading.glsl')
SOURCES = SHADING_SOURCES + ('vpraster_lighting.glsl',)


def defines() -> dict:
    """Sizes shared with the engine, read from its Haxe sources (engine.py)."""
    return {
        'MAX_LIGHT_SOURCES': engine.max_lights(),
        'ARM_LIGHT_VEC4S': engine.light_vec4s(),
        'ARM_MAX_SHADOW_VIEWS': engine.max_shadow_views(),
        'ARM_SHADOW_VIEW_VEC4S': engine.shadow_view_vec4s(),
    }

# Uniforms the engine fills: name -> (shader data type, link)
CONSTANTS = {
    'u_viewPosition': ('vec3', '_cameraPosition'),
    'u_numActiveLightSources': ('int', '_vprasterLightCount'),
    'u_lightPacked': ('floats', '_vprasterLights'),
    'u_envMatrix': ('mat4', '_vprasterEnvMatrix'),
    'u_envLightIntensity': ('float', '_vprasterEnvIntensity'),
    'u_envRadianceMips': ('int', '_vprasterEnvMips'),
    'u_armDirect': ('vec2', '_vprasterDirect'),
    'u_armIndirect': ('vec2', '_vprasterIndirect'),
    'u_armViewDir': ('vec4', '_vprasterViewDir'),
    'u_armShadows': ('floats', '_vprasterShadows'),
    'u_armShadowInfo': ('vec4', '_vprasterShadowInfo'),
    'invVP': ('mat4', '_inverseViewProjectionMatrix'),
}
TEXTURES = {
    'u_envRadiance': {'link': '_vprasterEnvRadiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                      'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'linear'},
    'u_envIrradiance': {'link': '_vprasterEnvIrradiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                        'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    'u_armDfg': {'link': '_vprasterDfg', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                 'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    'u_armLtc': {'link': '_vprasterLtc', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                 'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    # The shadow atlas's depth buffer (Iron binds links ending in _depth as depth
    # textures), compared by hand (bilinear-weighted) in vpraster_lights.glsl
    'u_armShadowMap': {'link': '_vprasterShadowMap_depth', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                       'filter_min': 'point', 'filter_mag': 'point', 'mipmap_filter': 'none'},
}
# Bound by RenderPathViewportRaster (bindTarget)
TARGETS = ['gbuffer0', 'gbuffer1', 'gbuffer2', 'gbuffer3', 'gbuffer4', 'gbufferDepth']


def build():
    for name, flags in VARIANTS.items():
        build_pass(name, source(flags))


def build_pass(name: str, frag: str):
    build_shaders = files.build_shaders()
    files.write_generated(os.path.join(build_shaders, name + '.frag.glsl'), frag)

    context = {
        'name': name,
        'depth_write': False,
        'compare_mode': 'always',
        'cull_mode': 'none',
        'vertex_elements': [{'name': 'pos', 'data': 'float2'}],
        'color_attachments': ['RGBA64'],
        'vertex_shader': 'pass.vert',
        'fragment_shader': name + '.frag',
        'texture_units': [],
        'constants': [],
    }
    for kind, uniform in glsl_rewrite.uniforms(frag):
        if uniform in CONSTANTS:
            ctype, link = CONSTANTS[uniform]
            context['constants'].append({'name': uniform, 'type': ctype, 'link': link})
        elif uniform in TEXTURES:
            context['texture_units'].append(dict({'name': uniform}, **TEXTURES[uniform]))
        elif uniform in TARGETS:
            context['texture_units'].append({'name': uniform})
        else:
            raise RuntimeError('Viewport renderer: no binding for lighting pass uniform %s %s' % (kind, uniform))

    path = os.path.join(build_shaders, name + '.arm')
    arm.utils.write_arm(path, {'shader_datas': [{'name': name, 'contexts': [context]}]})
    assets.add_shader_data(path)


def source(flags: tuple = ()) -> str:
    folder = files.sdk_shaders()
    parts = ['#version 450', '#include "compiled.inc"']
    parts += ['#define %s %d' % item for item in defines().items()]
    parts += ['#define ' + flag for flag in flags]
    # Inlined, not #included: khamake recompiles a shader only when its own text changes
    for name in ('vpraster_common.inc',) + SOURCES:
        with open(os.path.join(folder, name), encoding='utf-8') as f:
            parts.append(f.read())
    return '\n'.join(parts)


def shading_library() -> str:
    """arm_shade() and what it needs, for a shader that already has vpraster_common.inc
    (blended materials: arm_gbuffer.glsl includes it)."""
    folder = files.sdk_shaders()
    parts = []
    for name in SHADING_SOURCES:
        with open(os.path.join(folder, name), encoding='utf-8') as f:
            parts.append(f.read())
    return '\n'.join(parts)
