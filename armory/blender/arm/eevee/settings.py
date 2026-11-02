"""Blender's Eevee and render settings the Eevee renderer reads at runtime.

Written as eevee_settings.json next to the other assets and loaded by
armory.renderpath.eevee.EeveeSettings.
"""
import json

FILE = 'eevee_settings.json'


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
    }
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=1)
