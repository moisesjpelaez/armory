"""World export for the Eevee renderer.

build() replaces make_world.build(): every exported world is rendered by
Blender into a latlong image (so any world node tree works: sky textures,
HDRIs, strength...) and baked by cmft into prefiltered radiance mipmaps and
spherical harmonics irradiance, at the world's light probe resolution. Bakes
are named after the world's content (world_key()): an unchanged world is not
rendered or baked again.
export() replaces the exporter's post_export_world(). No world shader is
generated: the render path draws the sky from the radiance image.

Sun extraction (world.sun_threshold), as measured on Eevee: light brighter
than the threshold is taken out of the world lighting and becomes one sun
light; the world keeps the light up to the threshold. Eevee's result is then
physically exact (the sun gets exactly the excess energy), while its world
lighting alone smears small bright sources.
"""
import hashlib
import json
import math
import os

import bpy
import numpy as np

import arm
import arm.eevee.context as context
import arm.eevee.files as files
import arm.eevee.mx_export as mx_export
import arm.log as log
import arm.utils
import arm.write_probes as write_probes

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    mx_export = arm.reload_module(mx_export)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
    write_probes = arm.reload_module(write_probes)
else:
    arm.enable_reload(__name__)

VERSION = '1'  # bump when the render, the sun extraction or the bake changes
# cmft's mip chain in write_probes supports these map widths
RADIANCE_SIZES = (512, 1024, 2048)



def exported_worlds() -> list:
    """Worlds of exported scenes, plus fake-user worlds (as make_world.build())."""
    used = {scene.world.name for scene in bpy.data.scenes if scene.arm_export and scene.world is not None}
    return [world for world in bpy.data.worlds
            if world.name in used or (world.use_fake_user and world.name != 'Arm')]


def radiance_size(world) -> int:
    """The world's light probe resolution, within what the bake supports (warns otherwise)."""
    size = int(world.probe_resolution)
    clamped = min(max(size, RADIANCE_SIZES[0]), RADIANCE_SIZES[-1])
    if clamped != size:
        log.warn('Eevee renderer: world "%s": light probe resolution %d is not supported, baked at %d '
                 '(supported: %s)' % (world.name, size, clamped, ', '.join(str(s) for s in RADIANCE_SIZES)))
    return clamped


def build():
    bpy.data.worlds['Arm'].world_defs = ''
    envpath = files.build_assets('envmaps')
    ctx = context.current()
    # write_probes renders worlds to 8-bit sRGB JPEG by default: display-encoded
    # and clipped at 1.0. The Eevee renderer needs linear HDR light.
    for world in exported_worlds():
        size = radiance_size(world)
        # Named after the world's content: an edited world gets a new bake,
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
        # The bake is kept when its files exist: count their mips on disk rather
        # than trusting the count saved in the .blend (0 if it wasn't saved)
        world.arm_envtex_num_mips = write_probes.write_probes(
            image_path, False, False, baked_mips(envpath, image_file), True, size)
        if not os.path.isfile(sun_path):
            with open(sun_path, 'w', encoding='utf-8') as f:
                json.dump(sun, f)  # written last: marks the bake as complete
        if sun is not None:
            ctx.extracted_suns[world.name] = dict(sun, angle=world.sun_angle, shadow=world.use_sun_shadow)
    write_probes.check_last_cmft_time()
    prune()


def prune():
    """Deletes the bakes of worlds that changed or are no longer exported."""
    files.prune(files.build_assets('envmaps'), set(), lambda name: name.startswith('env_') and
                not any(name.startswith(base + '_') or name.startswith(base + '.') for base in context.current().bakes))


def world_key(world, size: int) -> str:
    """Everything the world's render, sun extraction and bake depend on."""
    parts = [VERSION, bpy.app.version_string, str(size), repr(world.sun_threshold),
             repr(world.use_nodes), repr(tuple(world.color))]
    if world.use_nodes and world.node_tree is not None:
        parts.append(mx_export.tree_signature(world.node_tree, set()))
    return hashlib.sha1('|'.join(parts).encode()).hexdigest()[:12]


def baked_mips(envpath: str, image_file: str) -> int:
    """Mip levels of an existing radiance bake (<image>_radiance_<i>.hdr), 0 if none."""
    base = os.path.join(envpath, image_file.rsplit('.', 1)[0] + '_radiance_')
    count = 0
    while os.path.isfile('%s%d.hdr' % (base, count)):
        count += 1
    return count


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
    radiance = world.arm_envtex_name.rsplit('.', 1)[0] + '_radiance.hdr'
    out_world['probe'] = {
        'name': arm.utils.asset_name(world),
        'irradiance': world.arm_envtex_irr_name + '_irradiance' + ('' if wrd.arm_minimize else '.json'),
        'radiance': radiance,
        'radiance_mipmaps': world.arm_envtex_num_mips,
        # The render already includes the Background node's strength
        'strength': 1.0,
    }
    sun = context.current().extracted_suns.get(world.name)
    if sun is not None:
        out_world['eevee_sun'] = sun
