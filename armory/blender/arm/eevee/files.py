"""Folders and file writes shared by the Eevee renderer's build modules."""
import os

import arm
import arm.utils

if arm.is_reload(__name__):
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)


def sdk_shaders(*parts: str) -> str:
    """A path under the renderer's own shaders, armory/Shaders/eevee."""
    return os.path.join(arm.utils.get_sdk_path(), 'armory', 'Shaders', 'eevee', *parts)


def build_shaders() -> str:
    """compiled/Shaders of the build folder (khamake compiles every .glsl in it)."""
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Shaders')
    os.makedirs(folder, exist_ok=True)
    return folder


def build_assets(*parts: str) -> str:
    """A path under compiled/Assets of the build folder (packed whole into the game)."""
    return os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets', *parts)


def prune(folder: str, keep: set, owned=lambda name: True):
    """Deletes the files in `folder` this build no longer uses: those `owned`
    (written by the renderer) and not in `keep`. The build folder is kept between
    builds, and compiled/Assets and compiled/Shaders are packed whole, so a stale
    file would ship with the game."""
    if not os.path.isdir(folder):
        return
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and owned(name) and name not in keep:
            os.remove(path)


def resolve(template: str, flags: set, defines: dict = None) -> str:
    """A shader template from Shaders/eevee with its renderer options applied: the
    file's #include "..." are inlined, #ifdef / #ifndef / #else / #endif on ARM_
    names are evaluated against `flags`, and `defines` (name -> value) are written
    after #version. Other directives are left to the shader compiler. The result is
    exactly what gets compiled, so its inputs and uniforms can be read from it."""
    with open(sdk_shaders(template), encoding='utf-8') as f:
        lines = f.read().split('\n')
    out = []
    stack = []  # per open #if: (ours, taking)

    def taking():
        return all(take for ours, take in stack if ours)

    for line in lines:
        words = line.strip().split()
        directive = words[0] if words else ''
        if directive in ('#ifdef', '#ifndef') and words[1].startswith('ARM_'):
            stack.append((True, (words[1] in flags) == (directive == '#ifdef')))
            continue
        if directive in ('#if', '#ifdef', '#ifndef'):
            stack.append((False, True))
        elif directive == '#else' and stack and stack[-1][0]:
            stack[-1] = (True, not stack[-1][1])
            continue
        elif directive == '#endif':
            ours = stack.pop()[0]
            if ours:
                continue
        if not taking():
            continue
        if directive == '#include':
            out.append(resolve(words[1].strip('"'), flags))
            continue
        out.append(line)
        if directive == '#version' and defines:
            out += ['#define %s %s' % item for item in defines.items()]
    if stack:
        raise RuntimeError('Eevee renderer: unterminated #if in %s' % template)
    return '\n'.join(out)
