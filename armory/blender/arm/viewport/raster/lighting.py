"""Lighting pass of the Viewport renderer: one full-screen shader per project.

It lights every pixel of the material images (arm_gbuffer.glsl) the way Eevee
shades Blender's Principled BSDF. The shader is our own GLSL from Shaders/vpraster.
It is assembled here from vpraster_common.inc (noise, latlong mapping, world positions, octahedral normals) and:
  vpraster_specular.glsl   Eevee's reflectance table and lamp lobe
  vpraster_lights.glsl     light data, lamps (arm_light) and soft shadows
  vpraster_shading.glsl    light scales and the surface model, arm_shade()
  vpraster_lighting.glsl   main(), which reads the material images and calls arm_shade()
Blended materials use the same shading files with their own main()
(shading_library(), used by materials.py).

RenderPathViewportRaster draws this pass into vpraster_hdr after the material pass.

Six versions are built (VARIANTS). Each one leaves out code a frame may not need:
  ARM_POINT_LAMPS        Every lamp is a point, so there are no lamp outlines
                         (RasterLights.outlines).
  ARM_SHADOWS_FROM_PASS  Shadows are read from the shadow pass's image, so there
                         is no shadow code. Used with up to RasterLights.PASS_LIGHTS
                         shadow-casting lights.
  ARM_SUN_SHADOWS_ONLY   No spot, point or area light casts a shadow
                         (RasterLights.localShadows), so there are no perspective
                         shadow views.
Each frame, RenderPathViewportRaster.choosePasses() picks the version it needs and
loads it the first time. That version draws the same image as the full shader,
only faster: code that never runs still slows a shader down. Blended materials
keep all the code (shading_library()).

The shadow pass (SHADOW_VARIANTS, vpraster_shadow_pass.glsl) runs before the
lighting pass when ARM_SHADOWS_FROM_PASS is used. It computes the shadows on its
own, with or without the perspective views (ARM_SUN_SHADOWS_ONLY), which is
faster than doing it inside the lighting pass.
"""
import os

import arm
import arm.viewport.raster.engine as engine
import arm.viewport.files as files
import arm.viewport.glsl as glsl
import arm.viewport.raster.state as state

if arm.is_reload(__name__):
    engine = arm.reload_module(engine)
    files = arm.reload_module(files)
    glsl = arm.reload_module(glsl)
    state = arm.reload_module(state)
else:
    arm.enable_reload(__name__)

# The lighting pass's versions: shader name -> defines that leave code out. Each is
# named after what it contains. The order must match RenderPathViewportRaster.LIGHTING,
# which picks a version by index: 1 adds lamp outlines, 2 adds spot, point and area
# shadows, 4 reads the shadows from the shadow pass. The shadow pass already holds
# every light's shadow, so 2 is never combined with 4.
VARIANTS = {
    'vpraster_lighting': ('ARM_POINT_LAMPS', 'ARM_SUN_SHADOWS_ONLY'),
    'vpraster_lighting_outlines': ('ARM_SUN_SHADOWS_ONLY',),
    'vpraster_lighting_local': ('ARM_POINT_LAMPS',),
    'vpraster_lighting_outlines_local': (),
    'vpraster_lighting_shadowpass': ('ARM_POINT_LAMPS', 'ARM_SHADOWS_FROM_PASS'),
    'vpraster_lighting_outlines_shadowpass': ('ARM_SHADOWS_FROM_PASS',),
}
# The shadow pass's versions, in the order of RenderPathViewportRaster.SHADOW_PASS:
# suns only, then with spot, point and area lights too
SHADOW_VARIANTS = {
    'vpraster_shadow_pass': ('ARM_SUN_SHADOWS_ONLY',),
    'vpraster_shadow_pass_local': (),
}
SHADING_SOURCES = ('vpraster_specular.glsl', 'vpraster_lights.glsl', 'vpraster_shading.glsl')
SOURCES = SHADING_SOURCES + ('vpraster_lighting.glsl',)
SHADOW_SOURCES = ('vpraster_specular.glsl', 'vpraster_lights.glsl', 'vpraster_shadow_pass.glsl')


def defines() -> dict:
    """Sizes, light kinds and limits shared with the engine, read from its Haxe sources (engine.py)."""
    values = {
        'MAX_LIGHT_SOURCES': engine.max_lights(),
        'ARM_LIGHT_VEC4S': engine.light_vec4s(),
        'ARM_MAX_SHADOW_VIEWS': engine.max_shadow_views(),
        'ARM_SHADOW_VIEW_VEC4S': engine.shadow_view_vec4s(),
        'ARM_MIN_OUTLINE_ANGLE': repr(engine.min_outline_angle()),
    }
    for light_type, code in engine.light_kinds().items():
        values['ARM_LIGHT_' + light_type] = code
    return values

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
    # The shadow atlas's depth buffer. Iron binds links ending in _depth as depth
    # textures. vpraster_lights.glsl does the depth comparison itself, with
    # bilinear weights, so the sampler uses point filtering.
    'u_armShadowMap': {'link': '_vprasterShadowMap_depth', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                       'filter_min': 'point', 'filter_mag': 'point', 'mipmap_filter': 'none'},
}
# Bound by RenderPathViewportRaster (bindTarget)
TARGETS = ['gbuffer0', 'gbuffer1', 'gbuffer2', 'gbuffer3', 'gbuffer4', 'gbufferDepth', 'u_armShadowVisibility']


def build():
    for name, flags in VARIANTS.items():
        build_pass(name, source(flags))
    for name, flags in SHADOW_VARIANTS.items():
        build_pass(name, source(flags, SHADOW_SOURCES))


def build_pass(name: str, frag: str):
    """Writes a full-screen pass's pixel shader and its shader data. Every uniform
    the shader declares must be in CONSTANTS, TEXTURES or TARGETS."""
    files.write_generated(os.path.join(files.build_shaders(), name + '.frag.glsl'), frag)

    texture_units = []
    constants = []
    for glsl_type, uniform in glsl.uniforms(frag):
        if uniform in CONSTANTS:
            ctype, link = CONSTANTS[uniform]
            constants.append({'name': uniform, 'type': ctype, 'link': link})
        elif uniform in TEXTURES:
            texture_units.append(dict({'name': uniform}, **TEXTURES[uniform]))
        elif uniform in TARGETS:
            texture_units.append({'name': uniform})
        else:
            raise RuntimeError('Viewport renderer: no binding for lighting pass uniform %s %s' % (glsl_type, uniform))
    files.write_pass_data(name, texture_units, constants)


def source(flags: tuple = (), sources: tuple = SOURCES) -> str:
    """A version's pixel shader: the engine's sizes and the version's `flags` as
    defines, followed by vpraster_common.inc and the `sources`."""
    folder = state.shaders()
    parts = ['#version 450', '#include "compiled.inc"']
    parts += ['#define %s %s' % item for item in defines().items()]
    parts += ['#define ' + flag for flag in flags]
    # Inlined, not #included: khamake recompiles a shader only when its own text changes
    for name in ('vpraster_common.inc',) + sources:
        with open(os.path.join(folder, name), encoding='utf-8') as f:
            parts.append(f.read())
    return '\n'.join(parts)


def shading_library() -> str:
    """arm_shade() and the code it needs, for a shader that already has
    vpraster_common.inc. Blended materials use it: their arm_gbuffer.glsl
    includes vpraster_common.inc."""
    folder = state.shaders()
    parts = []
    for name in SHADING_SOURCES:
        with open(os.path.join(folder, name), encoding='utf-8') as f:
            parts.append(f.read())
    return '\n'.join(parts)
