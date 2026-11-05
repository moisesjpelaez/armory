"""Values the build shares with the engine, read from the engine's Haxe sources.

The Haxe classes are the one place these sizes and names are written; the build
reads them for the shaders (lighting.py, vertex.py) and the shader data
(materials.py), so the three sides can't drift apart.
"""
import os
import re

import arm
import arm.utils

if arm.is_reload(__name__):
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

EEVEE = ('armory', 'renderpath', 'eevee')


def constant(parts: tuple, cls: str, name: str) -> str:
    """The value of `static [inline] var name = value;` in Sources/<parts>/<cls>.hx."""
    path = os.path.join(arm.utils.get_sdk_path(), 'armory', 'Sources', *parts, cls + '.hx')
    with open(path, encoding='utf-8') as f:
        match = re.search(r'\bstatic\s+(?:inline\s+)?var\s+%s\s*(?::\s*\w+\s*)?=\s*([^;]+);' % name, f.read())
    if match is None:
        raise RuntimeError('Eevee renderer: %s.%s not found in %s' % (cls, name, path))
    return match.group(1).strip()


def number(parts: tuple, cls: str, name: str) -> int:
    return int(constant(parts, cls, name))


def string(parts: tuple, cls: str, name: str) -> str:
    return constant(parts, cls, name).strip('"')


def max_lights() -> int:
    return number(EEVEE, 'EeveeUniforms', 'MAX_LIGHTS')


def light_vec4s() -> int:
    return number(EEVEE, 'EeveeUniforms', 'LIGHT_VEC4S')


def max_shadow_views() -> int:
    return number(EEVEE, 'EeveeShadows', 'MAX_VIEWS')


def shadow_view_vec4s() -> int:
    return number(EEVEE, 'EeveeShadows', 'VIEW_VEC4S')


def sun_cascades() -> int:
    return number(EEVEE, 'EeveeShadows', 'SUN_CASCADES')


def shadow_context() -> str:
    return string(EEVEE, 'EeveeShadows', 'CONTEXT')


def blend_context() -> str:
    return string(EEVEE, 'EeveeTransparency', 'CONTEXT')


def blend_depth_context() -> str:
    return string(EEVEE, 'EeveeTransparency', 'DEPTH_CONTEXT')


def blend_back_context() -> str:
    return string(EEVEE, 'EeveeTransparency', 'BACK_CONTEXT')


def blend_front_context() -> str:
    return string(EEVEE, 'EeveeTransparency', 'FRONT_CONTEXT')


def blend_opaque_context() -> str:
    return string(EEVEE, 'EeveeTransparency', 'OPAQUE_CONTEXT')


def aov_context(name: str) -> str:
    """A material's pass writing the AOV `name` (RenderPathEevee.aovContext())."""
    return '%s[%s]' % (string(EEVEE, 'RenderPathEevee', 'AOV_CONTEXT'), name)


def max_bones() -> int:
    return number(('iron', 'object'), 'BoneAnimation', 'skinMaxBones')
