"""Blender's Eevee and render settings the Eevee renderer reads at runtime.

Written per scene (eevee_settings_<scene>.json, listed in eevee_scenes.json)
and loaded by armory.renderpath.eevee.EeveeSettings when that scene is active.
"""
import json


def write(scene, path: str):
    eevee = scene.eevee
    render = scene.render
    settings = {
        'taa_samples': eevee.taa_samples,
        'filter_size': render.filter_size,
        'clamp_surface_direct': eevee.clamp_surface_direct,
        'clamp_surface_indirect': eevee.clamp_surface_indirect,
        'direct_light_intensity': eevee.direct_light_intensity,
        'indirect_light_intensity': eevee.indirect_light_intensity,
        'light_threshold': eevee.light_threshold,
        'resolution_percentage': render.resolution_percentage,
        'film_transparent': render.film_transparent,
        'dither_intensity': render.dither_intensity,
        'use_shadows': eevee.use_shadows,
        'shadow_pool_size': int(eevee.shadow_pool_size),  # MB
        'shadow_step_count': eevee.shadow_step_count,
    }
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=1)
