"""World export for the Viewport renderer.

build() runs in place of make_world.build(). Blender renders every exported
world into a latlong image, so any world node tree works (sky textures, HDRIs,
strength and so on). cmft then bakes the image into prefiltered radiance mipmaps
and spherical harmonics irradiance, at the world's light probe resolution. Bakes
are named after the world's content (world_key()), so an unchanged world is not
rendered or baked again.

export() runs in place of the exporter's post_export_world(). No world shader is
generated: the render path draws the sky from the radiance image.

Sun extraction (world.sun_threshold) works as in Eevee. Light brighter than the
threshold is taken out of the world lighting and becomes one sun light, and the
world keeps the light up to the threshold. The sun gets exactly the excess
energy, so the total light is unchanged. World lighting alone would smear a small
bright source; as a sun it stays sharp and can cast shadows (use_sun_shadow).
"""
import json
import math
import os

import bpy
import numpy as np

import arm
import arm.viewport.context as context
import arm.viewport.files as files
import arm.viewport.signature as signature
import arm.viewport.raster.state as state
import arm.viewport.raster.settings as settings
import arm.log as log
import arm.utils
import arm.write_probes as write_probes

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    signature = arm.reload_module(signature)
    state = arm.reload_module(state)
    settings = arm.reload_module(settings)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
    write_probes = arm.reload_module(write_probes)
else:
    arm.enable_reload(__name__)

# Map widths that cmft's mip chain in write_probes supports
RADIANCE_SIZES = (512, 1024, 2048)



def exported_worlds() -> list:
    """Worlds of exported scenes, plus worlds with a fake user (as make_world.build() does)."""
    used = {scene.world.name for scene in context.exported_scenes() if scene.world is not None}
    return [world for world in bpy.data.worlds
            if world.name in used or (world.use_fake_user and world.name != 'Arm')]


def radiance_size(world) -> int:
    """The world's light probe resolution, clamped to what the bake supports (with a warning)."""
    size = settings.number(world, 'probe_resolution',
                           'world "%s": World Properties > Settings > Light Probe > Resolution' % world.name)
    clamped = min(max(size, RADIANCE_SIZES[0]), RADIANCE_SIZES[-1])
    if clamped != size:
        log.warn('Viewport renderer: world "%s": light probe resolution %d is not supported, baked at %d '
                 '(supported: %s)' % (world.name, size, clamped, ', '.join(str(s) for s in RADIANCE_SIZES)))
    return clamped


def build():
    bpy.data.worlds['Arm'].world_defs = ''
    envpath = files.build_assets('envmaps')
    ctx = state.current()
    # write_probes renders worlds to 8-bit sRGB JPEG by default, which is
    # display-encoded and clipped at 1.0. The Viewport renderer needs linear HDR
    # light, so it asks for HDR images (setup_envmap_render() below).
    for world in exported_worlds():
        size = radiance_size(world)
        # Named after the world's content: an edited world gets a new bake, and
        # an unchanged one keeps its bake and is not rendered again
        image_file = 'env_%s_%s.hdr' % (arm.utils.safesrc(arm.utils.asset_name(world)), world_key(world, size))
        image_path = os.path.join(envpath, image_file)
        sun_path = image_path.rsplit('.', 1)[0] + '_sun.json'
        if os.path.isfile(sun_path):
            with open(sun_path, encoding='utf-8') as f:
                sun = json.load(f)
        else:
            os.makedirs(envpath, exist_ok=True)
            with write_probes.setup_envmap_render(size, image_format='HDR'):
                rendered = write_probes.render_envmap(envpath, world, ext='hdr')
            os.replace(os.path.join(envpath, rendered), image_path)
            sun = extract_sun(image_path, world.sun_threshold)
        world.arm_envtex_name = image_file
        world.arm_envtex_irr_name = image_file.rsplit('.', 1)[0]
        ctx.bakes.add(world.arm_envtex_irr_name)
        # write_probes keeps the bake when its files exist. The mips are counted on
        # disk, because the count saved in the .blend is 0 if the file wasn't saved.
        world.arm_envtex_num_mips = write_probes.write_probes(
            image_path, False, False, baked_mips(envpath, image_file), True, size)
        if not os.path.isfile(sun_path):
            files.write_if_changed(sun_path, json.dumps(sun))  # written last: marks the bake as complete
        if sun is not None:
            ctx.extracted_suns[world.name] = dict(sun, angle=world.sun_angle, shadow=world.use_sun_shadow)
    write_probes.check_last_cmft_time()
    prune()


def prune():
    """Deletes the bakes of worlds that changed or are no longer exported."""
    files.prune(files.build_assets('envmaps'), set(), lambda name: name.startswith('env_') and
                not any(name.startswith(base + '_') or name.startswith(base + '.') for base in state.current().bakes))


def world_key(world, size: int) -> str:
    """Everything the world's render, sun extraction and bake depend on."""
    # The code that renders, extracts and bakes (this module, write_probes.py)
    code = files.source_key(os.path.abspath(__file__), os.path.abspath(write_probes.__file__))
    parts = [code, bpy.app.version_string, str(size), repr(world.sun_threshold),
             repr(world.use_nodes), repr(tuple(world.color))]
    if world.use_nodes and world.node_tree is not None:
        parts.append(signature.tree_signature(world.node_tree, context.current().group_signatures))
    return files.short_hash('|'.join(parts))


def baked_mips(envpath: str, image_file: str) -> int:
    """Mip levels of an existing radiance bake (<image>_radiance_<i>.hdr), 0 if none."""
    base = os.path.join(envpath, image_file.rsplit('.', 1)[0] + '_radiance_')
    count = 0
    while os.path.isfile('%s%d.hdr' % (base, count)):
        count += 1
    return count


def extract_sun(image_path: str, threshold: float):
    """Caps the world image at `threshold`, keeping each pixel's hue, and saves it.
    Returns the light that was cut off as one sun, {'direction', 'color',
    'strength'}, or None if nothing was above the threshold.

    The image is write_probes' world render. It is equirectangular, looking along
    +X with +Z up, so the centre is +X and -Y is to its right.
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
    """Writes the world's fields: its baked probe and its extracted sun, if any."""
    wrd = bpy.data.worlds['Arm']
    out_world['background_color'] = arm.utils.color_to_int(world.arm_envtex_color)
    radiance = world.arm_envtex_name.rsplit('.', 1)[0] + '_radiance.hdr'
    out_world['probe'] = {
        'name': arm.utils.asset_name(world),
        'irradiance': world.arm_envtex_irr_name + '_irradiance' + ('' if wrd.arm_minimize else '.json'),
        'radiance': radiance,
        'radiance_mipmaps': world.arm_envtex_num_mips,
        # The render already includes the Background node's strength
        'strength': 1.0,
    }
    sun = state.current().extracted_suns.get(world.name)
    if sun is not None:
        out_world['vpraster_sun'] = sun
