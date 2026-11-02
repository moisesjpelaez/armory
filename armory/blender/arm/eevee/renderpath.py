"""Render path setup for the Eevee renderer (called from make_renderpath.build())."""
import os

import arm
import arm.assets as assets
import arm.eevee.color as color
import arm.eevee.settings as settings
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    color = arm.reload_module(color)
    settings = arm.reload_module(settings)
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
    # Meshes keep last frame's world matrix (MeshObject.prevMatrix) for velocity
    assets.add_khafile_def('arm_veloc')
    assets.add_shader_pass('eevee_world_pass')
    assets.add_shader_pass('eevee_taa_pass')
    assets.add_shader_pass('eevee_film_pass')
    build_scene_settings()


def build_scene_settings():
    """Exports the played scene's Eevee settings and bakes its colour management."""
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets')
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, FILM_LUT)
    scene = arm.utils.get_active_scene()
    color.build(scene, path)
    assets.add(path)

    settings_path = os.path.join(folder, settings.FILE)
    settings.write(scene, settings_path)
    assets.add(settings_path)
