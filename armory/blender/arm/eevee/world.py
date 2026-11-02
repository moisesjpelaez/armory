"""World export for the Eevee renderer.

build() replaces make_world.build(): every exported world is rendered by
Blender into a latlong image (so any world node tree works: sky textures,
HDRIs, strength...) and baked by cmft into prefiltered radiance mipmaps and
spherical harmonics irradiance, at the world's light probe resolution.
export() replaces the exporter's post_export_world(). No world shader is
generated: the render path draws the sky from the radiance image.

Sun extraction (world.sun_threshold), as measured on Eevee: light brighter
than the threshold is taken out of the world lighting and becomes one sun
light; the world keeps the light up to the threshold. Eevee's result is then
physically exact (the sun gets exactly the excess energy), while its world
lighting alone smears small bright sources.
"""
import math
import os

import bpy
import numpy as np

import arm
import arm.utils
import arm.write_probes as write_probes

if arm.is_reload(__name__):
    arm.utils = arm.reload_module(arm.utils)
    write_probes = arm.reload_module(write_probes)
else:
    arm.enable_reload(__name__)

# cmft's mip chain in write_probes supports these map widths
RADIANCE_SIZES = (512, 1024, 2048)

_extracted_suns = {}  # world name -> sun dict for export(), filled by build()


def exported_worlds() -> list:
    """Worlds of exported scenes, plus fake-user worlds (as make_world.build())."""
    used = {scene.world.name for scene in bpy.data.scenes if scene.arm_export and scene.world is not None}
    return [world for world in bpy.data.worlds
            if world.name in used or (world.use_fake_user and world.name != 'Arm')]


def radiance_size(world) -> int:
    """The world's light probe resolution, clamped to what the bake supports."""
    size = int(world.probe_resolution)
    return min(max(size, RADIANCE_SIZES[0]), RADIANCE_SIZES[-1])


def build():
    bpy.data.worlds['Arm'].world_defs = ''
    envpath = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets', 'envmaps')
    _extracted_suns.clear()

    # write_probes renders worlds to 8-bit sRGB JPEG by default: display-encoded
    # and clipped at 1.0. The Eevee renderer needs linear HDR light.
    saved_format, saved_ext = write_probes.ENVMAP_FORMAT, write_probes.ENVMAP_EXT
    write_probes.ENVMAP_FORMAT, write_probes.ENVMAP_EXT = 'HDR', 'hdr'
    try:
        for world in exported_worlds():
            size = radiance_size(world)
            with write_probes.setup_envmap_render(size):
                image_file = write_probes.render_envmap(envpath, world)
            image_path = os.path.join(envpath, image_file)
            sun = extract_sun(image_path, world.sun_threshold)
            if sun is not None:
                sun['angle'] = world.sun_angle
                sun['shadow'] = world.use_sun_shadow
                _extracted_suns[world.name] = sun
            world.arm_envtex_name = image_file
            world.arm_envtex_irr_name = image_file.rsplit('.', 1)[0]
            world.arm_envtex_num_mips = write_probes.write_probes(
                image_path, False, False, world.arm_envtex_num_mips, True, size)
    finally:
        write_probes.ENVMAP_FORMAT, write_probes.ENVMAP_EXT = saved_format, saved_ext
    write_probes.check_last_cmft_time()


def extract_sun(image_path: str, threshold: float):
    """Caps the world image at `threshold` (keeping each pixel's hue) and returns
    the cut-off light as one sun: {'direction', 'color', 'strength'}, or None.

    The image is write_probes' world render: equirectangular, looking along +X
    with +Z up, so the centre is +X and -Y is to its right.
    """
    if threshold <= 0.0:
        return None
    image = bpy.data.images.load(image_path, check_existing=False)
    try:
        width, height = image.size
        pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)  # row 0 = bottom
        rgb = pixels[..., :3]
        peak = rgb.max(axis=2)
        bright = peak > threshold
        if not bright.any():
            return None

        latitude = ((np.arange(height) + 0.5) / height - 0.5) * math.pi
        longitude = ((np.arange(width) + 0.5) / width - 0.5) * 2.0 * math.pi
        lon, lat = np.meshgrid(longitude, latitude)
        directions = np.stack([np.cos(lat) * np.cos(lon), -np.cos(lat) * np.sin(lon), np.sin(lat)], axis=-1)
        solid_angle = (2.0 * math.pi / width) * (math.pi / height) * np.cos(lat)

        scale = np.where(bright, threshold / np.maximum(peak, 1e-8), 1.0)[..., None]
        excess = rgb * (1.0 - scale)
        irradiance = (excess * solid_angle[..., None]).sum(axis=(0, 1))   # W/m2 at normal incidence
        weight = (excess.max(axis=2) * solid_angle)[..., None]
        towards_sun = (directions * weight).sum(axis=(0, 1))
        towards_sun /= max(np.linalg.norm(towards_sun), 1e-8)

        pixels[..., :3] = rgb * scale
        image.pixels[:] = pixels.ravel()
        image.save()
    finally:
        bpy.data.images.remove(image)

    strength = float(irradiance.max())
    if strength <= 0.0:
        return None
    return {
        'direction': [float(-v) for v in towards_sun],  # where the light travels
        'color': [float(v / strength) for v in irradiance],
        'strength': strength,
    }


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
    sun = _extracted_suns.get(world.name)
    if sun is not None:
        out_world['eevee_sun'] = sun
