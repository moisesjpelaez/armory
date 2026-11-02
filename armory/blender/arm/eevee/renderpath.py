"""Render path setup for the Eevee renderer (called from make_renderpath.build())."""
import os

import bpy

import arm
import arm.assets as assets
import arm.eevee.color as color
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    color = arm.reload_module(color)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

FILM_LUT = 'eevee_film_lut.bin'


def build():
    assets.add_khafile_def('rp_renderer=Eevee')
    # Shared Iron code tests these old render path features with `!= "Off"`,
    # which is true when they are not defined at all.
    assets.add_khafile_def('rp_voxels=Off')
    assets.add_khafile_def('rp_ssgi=Off')
    assets.add_shader_pass('eevee_world_pass')
    assets.add_shader_pass('eevee_film_pass')
    build_film()


def build_film():
    """Bakes the played scene's colour management for the film pass."""
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets')
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, FILM_LUT)
    scene = arm.utils.get_active_scene()
    datafiles = os.path.join(bpy.utils.resource_path('LOCAL'), 'datafiles')
    for warning in color.build(scene, datafiles, path):
        log.warn('Eevee renderer: %s (scene "%s")' % (warning, scene.name))
    assets.add(path)
