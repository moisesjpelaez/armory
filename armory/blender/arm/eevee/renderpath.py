"""Render path setup for the Eevee renderer (called from make_renderpath.build())."""
import arm
import arm.assets as assets

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
else:
    arm.enable_reload(__name__)


def build():
    assets.add_khafile_def('rp_renderer=Eevee')
    # Shared Iron code tests these old render path features with `!= "Off"`,
    # which is true when they are not defined at all.
    assets.add_khafile_def('rp_voxels=Off')
    assets.add_khafile_def('rp_ssgi=Off')
    assets.add_shader_pass('eevee_world_pass')
    assets.add_shader_pass('eevee_film_pass')
