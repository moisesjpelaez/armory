"""Colour management for the Eevee renderer: Blender's own colour pipeline
baked into a 3D lookup table the film pass applies.

The table's input grid (scene linear colours, Linear Rec.709 like the shaders
render) is written into an image and saved with image.save_render(), so Blender
applies the scene's complete colour management to it: display, view transform,
look, exposure, gamma, curves and white balance. HDR input goes through a log2
shaper first so 24 stops fit. Exposure and gamma are part of the table; the
header keeps neutral values for the film pass.

File layout (little-endian): a float32 header of HEADER_FLOATS values
  [version, size, min_stop, max_stop, exposure, gamma, 0, 0]
then size^3 RGBA float16 texels as a 2D strip (size*size wide, size high):
texel (r + b * size, g) holds the output for shaper coordinates (r, g, b).

The size is odd so a sample lands exactly on 1.0 (stop 0), where views like
Standard clip: with an even size the clip fell between two samples and white
came out at 0.91. A 49^3 table stays within ~0.15 8-bit steps of exact OCIO on average (1-2
steps for 99% of HDR colours) for AgX, Filmic, Standard and Khronos PBR
Neutral. False Color's hard-edged bands blur at any table size.
"""
import hashlib
import os
import struct

import bpy
import numpy as np

LUT_SIZE = 49  # odd: one sample at stop 0 (see above)
MIN_STOP = -12.0
MAX_STOP = 12.0
VERSION = 2
HEADER_FLOATS = 8


def shaper_to_linear(t: np.ndarray) -> np.ndarray:
    return np.exp2(MIN_STOP + t * (MAX_STOP - MIN_STOP))


def input_strip(size: int) -> np.ndarray:
    """The table's input: scene linear colours, (size, size * size, 4), row 0 = g 0."""
    axis = np.arange(size, dtype=np.float32) / (size - 1)
    b, g, r = np.meshgrid(axis, axis, axis, indexing='ij')  # [b][g][r]
    linear = shaper_to_linear(np.stack([r, g, b], axis=-1))
    strip = np.ones((size, size * size, 4), dtype=np.float32)  # [g][r + b * size]
    for bi in range(size):
        strip[:, bi * size:(bi + 1) * size, :3] = linear[bi]
    return strip


def bake(scene, temp_png: str, size: int = LUT_SIZE) -> np.ndarray:
    """Runs the input strip through the scene's colour management (16-bit PNG, no dither)."""
    strip = input_strip(size)
    image = bpy.data.images.new('_arm_eevee_lut', size * size, size, alpha=True, float_buffer=True)
    image.pixels[:] = strip[::-1].ravel()  # Blender image rows are bottom-up

    settings = scene.render.image_settings
    saved = (settings.file_format, settings.color_depth, settings.color_mode, scene.render.dither_intensity)
    try:
        settings.file_format, settings.color_depth, settings.color_mode = 'PNG', '16', 'RGBA'
        scene.render.dither_intensity = 0.0
        image.save_render(temp_png, scene=scene)
    finally:
        settings.file_format, settings.color_depth, settings.color_mode, scene.render.dither_intensity = saved
        bpy.data.images.remove(image)

    out = bpy.data.images.load(temp_png, check_existing=False)
    try:
        out.colorspace_settings.name = 'Non-Color'  # read the stored display values unchanged
        result = np.array(out.pixels[:], dtype=np.float32).reshape(size, size * size, 4)[::-1]
    finally:
        bpy.data.images.remove(out)
        os.remove(temp_png)
    result[..., 3] = 1.0
    return result


def pack(strip: np.ndarray, exposure: float, gamma: float) -> bytes:
    size = strip.shape[0]
    header = struct.pack('<%df' % HEADER_FLOATS, VERSION, size, MIN_STOP, MAX_STOP, exposure, gamma, 0.0, 0.0)
    return header + strip.astype('<f2').tobytes()


def settings_key(scene) -> str:
    """Identifies the table a scene bakes to: every property of its view and display
    settings and of the render output's image settings (an output colour management
    override applies to save_render too), plus this module and Blender's version.
    Listing every property, not chosen ones, means a setting can't be missed."""
    with open(os.path.abspath(__file__), 'rb') as f:
        parts = [hashlib.sha1(f.read()).hexdigest(), bpy.app.version_string]
    for struct in (scene.view_settings, scene.display_settings, scene.render.image_settings):
        rna_dump(struct, parts, 0)
    return hashlib.sha1('|'.join(parts).encode()).hexdigest()[:12]


def rna_dump(struct, parts: list, depth: int):
    """Appends every property of `struct` (nested structs and collections included)."""
    for prop in struct.bl_rna.properties:
        if prop.identifier == 'rna_type':
            continue
        value = getattr(struct, prop.identifier)
        if prop.type == 'POINTER':
            if value is not None and not isinstance(value, bpy.types.ID) and depth < 6:
                parts.append(prop.identifier + '{')
                rna_dump(value, parts, depth + 1)
                parts.append('}')
        elif prop.type == 'COLLECTION':
            parts.append(prop.identifier + '[')
            if depth < 6:
                for item in value:
                    rna_dump(item, parts, depth + 1)
            parts.append(']')
        else:
            parts.append('%s=%r' % (prop.identifier, tuple(value) if hasattr(value, '__len__') and not isinstance(value, str) else value))


def build(scene, temp_png: str) -> bytes:
    """The scene's colour management as a table file's contents."""
    return pack(bake(scene, temp_png), 0.0, 1.0)  # exposure and gamma are in the table
