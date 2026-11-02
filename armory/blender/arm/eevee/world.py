"""World export for the Eevee renderer.

build() replaces make_world.build(): every exported world is rendered by
Blender into a latlong image (so any world node tree works) and baked by cmft
into prefiltered radiance mipmaps and spherical harmonics irradiance.
export() replaces the exporter's post_export_world(). No world shader is
generated: the render path draws the sky from the radiance image.
"""
import os

import bpy

import arm
import arm.utils
import arm.write_probes as write_probes

if arm.is_reload(__name__):
    arm.utils = arm.reload_module(arm.utils)
    write_probes = arm.reload_module(write_probes)
else:
    arm.enable_reload(__name__)


def exported_worlds() -> list:
    """Worlds of exported scenes, plus fake-user worlds (as make_world.build())."""
    used = {scene.world.name for scene in bpy.data.scenes if scene.arm_export and scene.world is not None}
    return [world for world in bpy.data.worlds
            if world.name in used or (world.use_fake_user and world.name != 'Arm')]


def build():
    bpy.data.worlds['Arm'].world_defs = ''
    envpath = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets', 'envmaps')

    # write_probes renders worlds to 8-bit sRGB JPEG by default: display-encoded
    # and clipped at 1.0. The Eevee renderer needs linear HDR light.
    saved_format, saved_ext = write_probes.ENVMAP_FORMAT, write_probes.ENVMAP_EXT
    write_probes.ENVMAP_FORMAT, write_probes.ENVMAP_EXT = 'HDR', 'hdr'
    try:
        with write_probes.setup_envmap_render():
            for world in exported_worlds():
                image_file = write_probes.render_envmap(envpath, world)
                world.arm_envtex_name = image_file
                world.arm_envtex_irr_name = image_file.rsplit('.', 1)[0]
                world.arm_envtex_num_mips = write_probes.write_probes(
                    os.path.join(envpath, image_file), False, False, world.arm_envtex_num_mips, True)
    finally:
        write_probes.ENVMAP_FORMAT, write_probes.ENVMAP_EXT = saved_format, saved_ext
    write_probes.check_last_cmft_time()


def export(world, out_world: dict):
    wrd = bpy.data.worlds['Arm']
    out_world['background_color'] = arm.utils.color_to_int(world.arm_envtex_color)
    radiance = world.arm_envtex_name.rsplit('.', 1)[0] + '_radiance'
    radiance += '.jpg' if world.arm_envtex_name.endswith('.jpg') else '.hdr'
    out_world['probe'] = {
        'name': arm.utils.asset_name(world),
        'irradiance': world.arm_envtex_irr_name + '_irradiance' + ('' if wrd.arm_minimize else '.json'),
        'radiance': radiance,
        'radiance_mipmaps': world.arm_envtex_num_mips,
        # The render already includes the Background node's strength
        'strength': 1.0,
    }
