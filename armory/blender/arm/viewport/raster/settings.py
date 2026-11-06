"""Blender's Eevee and render settings the Viewport renderer reads at runtime.

Written per scene (vpraster_settings_<scene>.json, listed in vpraster_scenes.json)
and loaded by armory.renderpath.viewport.raster.RasterSettings when that scene is active.
"""
import json

import arm
import arm.viewport.mx_export as mx_export
import arm.log as log

if arm.is_reload(__name__):
    mx_export = arm.reload_module(mx_export)
    log = arm.reload_module(log)
else:
    arm.enable_reload(__name__)


def number(owner, prop: str, where: str) -> int:
    """A size Blender stores as an enum option ('512'). A file can hold a value that
    matches no option (Blender then shows it blank and reads it as ''): that uses the
    option's default, with a warning naming the setting (`where`) to fix it."""
    value = getattr(owner, prop)
    if value.isdigit():
        return int(value)
    default = owner.bl_rna.properties[prop].default
    log.warn('Viewport renderer: %s is blank in Blender, using its default (%s); set it to remove this warning'
             % (where, default))
    return int(default)


def write(scene, path: str, compositor: dict):
    """`compositor`: the scene's compositor steps (compositor.build()), or None."""
    eevee = scene.eevee
    render = scene.render
    if eevee.use_raytracing:
        # Phase 5 (indirect light) is postponed: no reflections or Fast GI traced on screen
        log.warn('Viewport renderer: scene "%s": Raytracing is not supported yet; it renders as with Raytracing '
                 'off (no screen-space reflections or Fast GI)' % scene.name)
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
        'shadow_pool_size': number(eevee, 'shadow_pool_size',  # MB
                                   'scene "%s": Render Properties > Shadows > Pool Size' % scene.name),
        'shadow_step_count': eevee.shadow_step_count,
        # Images RenderPathViewportRaster draws the materials' AOV outputs into
        'aovs': [{'name': name, 'type': kind} for name, kind in mx_export.scene_aovs(scene)],
        'compositor': compositor,
    }
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=1)
