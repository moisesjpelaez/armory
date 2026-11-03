"""Lighting pass of the Eevee renderer: one full-screen shader per project.

MaterialX generates it once from Blender's default material (mx_export), so the
surface model is Blender's own Principled BSDF as exported to OpenPBR. The
surface inputs the material images hold (arm_gbuffer.glsl) are read per pixel;
every other input keeps the value Blender exports for a new material (coat,
sheen, subsurface, transmission and thin film off). The Eevee rewrites
(glsl_rewrite) then apply: lights, light scales, orthographic view, Eevee's
specular and lamp lobe, shadows.

RenderPathEevee draws it into eevee_hdr after the material pass.
"""
import hashlib
import os

import MaterialX as mx

import arm
import arm.assets as assets
import arm.eevee.glsl_rewrite as glsl_rewrite
import arm.eevee.materials as materials
import arm.eevee.mx_codegen as mx_codegen
import arm.eevee.mx_export as mx_export
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    glsl_rewrite = arm.reload_module(glsl_rewrite)
    materials = arm.reload_module(materials)
    mx_codegen = arm.reload_module(mx_codegen)
    mx_export = arm.reload_module(mx_export)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

NAME = 'eevee_lighting_pass'

# Surface input -> its value in the material images (see arm_gbuffer.glsl);
# the emission colour is stored already multiplied by its luminance
READS = {
    'base_color': 'armGbuffer0.rgb',
    'base_metalness': 'armGbuffer0.a',
    'specular_color': 'armGbuffer2.rgb',
    'specular_roughness': 'armGbuffer2.a',
    'emission_color': 'armGbuffer3.rgb',
    'emission_luminance': '1.0',
    'specular_weight': 'armGbuffer3.a',
    'specular_ior': 'armGbuffer4.z',
}
# MaterialX uniforms the engine fills: name -> (shader data type, link)
ENGINE_CONSTANTS = {
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
}
ENGINE_TEXTURES = {
    'u_envRadiance': {'link': '_eeveeEnvRadiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                      'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'linear'},
    'u_envIrradiance': {'link': '_eeveeEnvIrradiance', 'addressing_u': 'repeat', 'addressing_v': 'clamp',
                        'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    'u_armDfg': {'link': '_eeveeDfg', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                 'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    'u_armLtc': {'link': '_eeveeLtc', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                 'filter_min': 'linear', 'filter_mag': 'linear', 'mipmap_filter': 'none'},
    # Depth atlas, compared by hand (bilinear-weighted) in glsl_rewrite.SHADOWS
    'u_armShadowMap': {'link': '_eeveeShadowMap', 'addressing_u': 'clamp', 'addressing_v': 'clamp',
                       'filter_min': 'point', 'filter_mag': 'point', 'mipmap_filter': 'none'},
}
# Generated but unused with our options (prefiltered environment, no refraction); left unbound
IGNORED_UNIFORMS = {'u_envRadianceSamples', 'u_refractionTwoSided'}
# Bound by RenderPathEevee (bindTarget)
TARGETS = ['gbuffer0', 'gbuffer1', 'gbuffer2', 'gbuffer3', 'gbuffer4', 'gbufferDepth']
CONSTANTS = {'invVP': ('mat4', '_inverseViewProjectionMatrix')}


def build():
    """Writes the lighting pass (after mx_export.build(), which exports the default material)."""
    build_shaders = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Shaders')
    os.makedirs(build_shaders, exist_ok=True)
    frag_path = os.path.join(build_shaders, NAME + '.frag.glsl')
    key_path = os.path.join(build_shaders, NAME + '.key')
    document = mx_export.default_document()
    digest = hashlib.sha1(materials.generation_key().encode())
    for path in (document, os.path.abspath(__file__)):
        with open(path, 'rb') as f:
            digest.update(f.read())
    key = digest.hexdigest()
    if not (os.path.exists(frag_path) and os.path.exists(key_path) and open(key_path).read() == key):
        materials.write_if_changed(frag_path, generate(document))
        with open(key_path, 'w') as f:
            f.write(key)
    frag = open(frag_path, encoding='utf-8').read()

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
    for kind, name, is_array in glsl_rewrite.uniforms(frag):
        if name in ENGINE_CONSTANTS:
            ctype, link = ENGINE_CONSTANTS[name]
            context['constants'].append({'name': name, 'type': ctype, 'link': link})
        elif name in CONSTANTS:
            ctype, link = CONSTANTS[name]
            context['constants'].append({'name': name, 'type': ctype, 'link': link})
        elif name in ENGINE_TEXTURES:
            context['texture_units'].append(dict({'name': name}, **ENGINE_TEXTURES[name]))
        elif name in TARGETS:
            context['texture_units'].append({'name': name})
        elif name not in IGNORED_UNIFORMS:
            raise RuntimeError('Eevee renderer: no binding for lighting pass uniform %s %s' % (kind, name))

    path = os.path.join(build_shaders, NAME + '.arm')
    arm.utils.write_arm(path, {'shader_datas': [{'name': NAME, 'contexts': [context]}]})
    assets.add_shader_data(path)


def generate(document: str) -> str:
    library = mx_codegen.library(materials.data_dir())
    doc = mx.createDocument()
    mx.readFromXmlFile(doc, document)
    doc.setDataLibrary(library)
    surface = next(n for n in doc.getNodes() if n.getCategory() == 'open_pbr_surface')
    surface_inputs = {i.getName() for i in surface.getNodeDef().getActiveInputs()}
    frag = mx_codegen.generate_fragment(materials.data_dir(), document, NAME, surface.getName())
    frag = glsl_rewrite.flatten_varyings(frag)
    frag = glsl_rewrite.lighting_inputs(frag, surface_inputs, READS)
    frag = glsl_rewrite.pack_lights(frag)
    frag = glsl_rewrite.light_scales(frag)
    frag = glsl_rewrite.orthographic_view(frag)
    frag = glsl_rewrite.eevee_specular(frag)
    return frag
