"""Colour management for the Eevee renderer: Blender's own OpenColorIO config
baked into a 3D lookup table the film pass applies.

The table covers display + view transform + look, from scene linear
(Linear Rec.709, what the shaders render) to display-encoded values. HDR input
goes through a log2 shaper first so 24 stops fit. Exposure is applied before
the table and gamma after it, at runtime (Shaders/eevee_film_pass).

File layout (little-endian): a float32 header of HEADER_FLOATS values
  [version, size, min_stop, max_stop, exposure, gamma, 0, 0]
then size^3 RGBA float16 texels as a 2D strip (size*size wide, size high):
texel (r + b * size, g) holds the output for shaper coordinates (r, g, b).

A 48^3 table stays within ~0.15 8-bit steps of exact OCIO on average (1-2
steps for 99% of HDR colours) for AgX, Filmic, Standard and Khronos PBR
Neutral. False Color's hard-edged bands blur at any table size.
"""
import os
import struct

import numpy as np

LUT_SIZE = 48
MIN_STOP = -12.0
MAX_STOP = 12.0
VERSION = 1
HEADER_FLOATS = 8


def config_path(blender_datafiles: str) -> str:
    """Blender honours the OCIO environment variable before its bundled config."""
    return os.environ.get('OCIO') or os.path.join(blender_datafiles, 'colormanagement', 'config.ocio')


def processor(config_file: str, display: str, view: str, look: str):
    import PyOpenColorIO as ocio
    config = ocio.Config.CreateFromFile(config_file)
    transform = ocio.DisplayViewTransform(src='scene_linear', display=display, view=view)
    pipeline = ocio.LegacyViewingPipeline()
    pipeline.setDisplayViewTransform(transform)
    look = resolve_look(config, view, look)
    if look is not None:
        pipeline.setLooksOverride(look)
        pipeline.setLooksOverrideEnabled(True)
    return pipeline.getProcessor(config).getDefaultCPUProcessor()


def resolve_look(config, view: str, look: str):
    """Blender shows looks without their view prefix ("Punchy" for "AgX - Punchy")."""
    if not look or look == 'None':
        return None
    names = [l.getName() for l in config.getLooks()]
    for candidate in (look, '%s - %s' % (view, look)):
        if candidate in names:
            return candidate
    raise RuntimeError('Colour management look "%s" not found in the OCIO config' % look)


def shaper_to_linear(t: np.ndarray) -> np.ndarray:
    return np.exp2(MIN_STOP + t * (MAX_STOP - MIN_STOP))


def linear_to_shaper(c: np.ndarray) -> np.ndarray:
    stops = np.log2(np.maximum(c, 1e-10))
    return np.clip((stops - MIN_STOP) / (MAX_STOP - MIN_STOP), 0.0, 1.0)


def bake(cpu, size: int = LUT_SIZE) -> np.ndarray:
    """Returns the strip as a (size, size * size, 4) float32 array."""
    axis = np.arange(size, dtype=np.float32) / (size - 1)
    b, g, r = np.meshgrid(axis, axis, axis, indexing='ij')  # [b][g][r]
    linear = shaper_to_linear(np.stack([r, g, b], axis=-1)).astype(np.float32)
    flat = np.ascontiguousarray(linear.reshape(-1, 3))
    cpu.applyRGB(flat)
    out = flat.reshape(size, size, size, 3)  # [b][g][r]
    strip = np.ones((size, size * size, 4), dtype=np.float32)  # [g][r + b * size]
    for bi in range(size):
        strip[:, bi * size:(bi + 1) * size, :3] = out[bi]
    return strip


def lookup(strip: np.ndarray, linear: np.ndarray) -> np.ndarray:
    """CPU version of the film pass lookup (trilinear), for testing."""
    size = strip.shape[0]
    s = linear_to_shaper(linear) * (size - 1)
    i0 = np.floor(s).astype(int)
    i1 = np.minimum(i0 + 1, size - 1)
    f = s - i0

    def texel(ri, gi, bi):
        return strip[gi, ri + bi * size, :3]

    result = 0
    for dr, wr in ((i0[:, 0], 1 - f[:, 0]), (i1[:, 0], f[:, 0])):
        for dg, wg in ((i0[:, 1], 1 - f[:, 1]), (i1[:, 1], f[:, 1])):
            for db, wb in ((i0[:, 2], 1 - f[:, 2]), (i1[:, 2], f[:, 2])):
                result = result + texel(dr, dg, db) * (wr * wg * wb)[:, None]
    return result


def write(path: str, strip: np.ndarray, exposure: float, gamma: float):
    size = strip.shape[0]
    header = struct.pack('<%df' % HEADER_FLOATS, VERSION, size, MIN_STOP, MAX_STOP, exposure, gamma, 0.0, 0.0)
    with open(path, 'wb') as f:
        f.write(header)
        f.write(strip.astype('<f2').tobytes())


def build(scene, blender_datafiles: str, path: str) -> list:
    """Bakes the scene's colour management into `path`. Returns warnings for settings not supported yet."""
    view = scene.view_settings
    cpu = processor(config_path(blender_datafiles), scene.display_settings.display_device, view.view_transform, view.look)
    write(path, bake(cpu), view.exposure, view.gamma)
    warnings = []
    if view.use_curve_mapping:
        warnings.append('colour management curves are not supported yet')
    if getattr(view, 'use_white_balance', False):
        warnings.append('colour management white balance is not supported yet')
    return warnings
