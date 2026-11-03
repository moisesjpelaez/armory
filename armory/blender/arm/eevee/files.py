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
    (written by the renderer) and not in `keep`. compiled/Assets is packed whole,
    so a stale file would ship with the game."""
    if not os.path.isdir(folder):
        return
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and owned(name) and name not in keep:
            os.remove(path)


def write_if_changed(path: str, text: str):
    """Unchanged files keep their timestamp, so khamake does not recompile them."""
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            if f.read() == text:
                return
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
