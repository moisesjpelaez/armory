"""Values the build shares with the engine, read from the engine's Haxe sources.

The Haxe classes are the one place where these sizes and names are defined. The
build reads them for the shaders (lighting.py, vertex.py) and the shader data
(materials.py), so the engine, the shaders and the shader data always agree.
"""
import os
import re

import arm
import arm.utils

if arm.is_reload(__name__):
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

RASTER = ('armory', 'renderpath', 'viewport', 'raster')

# Haxe source path -> ((modification time, size), {constant name: value}, text).
# A build asks for these values many times, so a file is read again only when it changes.
_sources = {}


def constant(parts: tuple, cls: str, name: str) -> str:
    """The value of `static [inline] var name = value;` in Sources/<parts>/<cls>.hx."""
    path = os.path.join(arm.utils.get_sdk_path(), 'armory', 'Sources', *parts, cls + '.hx')
    stat = os.stat(path)
    stamp = (stat.st_mtime_ns, stat.st_size)
    cached = _sources.get(path)
    if cached is None or cached[0] != stamp:
        with open(path, encoding='utf-8') as f:
            cached = (stamp, {}, f.read())
        _sources[path] = cached
    _, values, text = cached
    if name not in values:
        match = re.search(r'\bstatic\s+(?:inline\s+)?var\s+%s\s*(?::\s*\w+\s*)?=\s*([^;]+);' % name, text)
        if match is None:
            raise RuntimeError('Viewport renderer: %s.%s not found in %s' % (cls, name, path))
        values[name] = match.group(1).strip()
    return values[name]


def number(parts: tuple, cls: str, name: str) -> int:
    return int(constant(parts, cls, name))


def string(parts: tuple, cls: str, name: str) -> str:
    return constant(parts, cls, name).strip('"')


def max_lights() -> int:
    return number(RASTER, 'RasterUniforms', 'MAX_LIGHTS')


def light_kinds() -> dict:
    """Light kind codes as RasterLights packs them: {'SUN': 0, 'POINT': 1, ...}."""
    return {light_type: number(RASTER, 'RasterLights', light_type) for light_type in ('SUN', 'POINT', 'SPOT', 'AREA')}


def min_outline_angle() -> float:
    """Smallest sun half angle drawn as a disc (RasterLights.MIN_OUTLINE_ANGLE)."""
    return float(constant(RASTER, 'RasterLights', 'MIN_OUTLINE_ANGLE'))


def light_vec4s() -> int:
    return number(RASTER, 'RasterUniforms', 'LIGHT_VEC4S')


def max_shadow_views() -> int:
    return number(RASTER, 'RasterShadows', 'MAX_VIEWS')


def shadow_view_vec4s() -> int:
    return number(RASTER, 'RasterShadows', 'VIEW_VEC4S')


def shadow_context() -> str:
    return string(RASTER, 'RasterShadows', 'CONTEXT')


def shadow_perspective_context() -> str:
    return string(RASTER, 'RasterShadows', 'PERSPECTIVE_CONTEXT')


def blend_context() -> str:
    return string(RASTER, 'RasterTransparency', 'CONTEXT')


def blend_depth_context() -> str:
    return string(RASTER, 'RasterTransparency', 'DEPTH_CONTEXT')


def blend_back_context() -> str:
    return string(RASTER, 'RasterTransparency', 'BACK_CONTEXT')


def blend_front_context() -> str:
    return string(RASTER, 'RasterTransparency', 'FRONT_CONTEXT')


def blend_opaque_context() -> str:
    return string(RASTER, 'RasterTransparency', 'OPAQUE_CONTEXT')


def late_context() -> str:
    """The pass that draws Blended materials without alpha into the material
    images, after the AOVs."""
    return string(RASTER, 'RenderPathViewportRaster', 'LATE_CONTEXT')


def aov_context(name: str) -> str:
    """A material's pass writing the AOV `name` (RenderPathViewportRaster.aovContext())."""
    return '%s[%s]' % (string(RASTER, 'RenderPathViewportRaster', 'AOV_CONTEXT'), name)


def max_bones() -> int:
    return number(('iron', 'object'), 'BoneAnimation', 'skinMaxBones')
