"""Folders and file writes shared by the Viewport renderer's build modules."""
import hashlib
import os

import arm
import arm.assets as assets
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

# Hex digits of the short hashes that name generated files (short_hash()). The
# pruning of material shaders relies on it (materials.prune()).
HASH_LENGTH = 12


def short_hash(content) -> str:
    """The first HASH_LENGTH hex digits of the SHA-1 of text (UTF-8) or bytes."""
    data = content.encode('utf-8') if isinstance(content, str) else bytes(content)
    return hashlib.sha1(data).hexdigest()[:HASH_LENGTH]


def sdk_shaders(folder: str, *parts: str) -> str:
    """A path under a renderer's shaders, armory/Shaders/<folder> (raster: state.shaders())."""
    return os.path.join(arm.utils.get_sdk_path(), 'armory', 'Shaders', folder, *parts)


def build_shaders() -> str:
    """compiled/Shaders of the build folder (khamake compiles every .glsl in it)."""
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Shaders')
    os.makedirs(folder, exist_ok=True)
    return folder


def build_assets(*parts: str) -> str:
    """A path under compiled/Assets of the build folder (packed whole into the game)."""
    return os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets', *parts)


def write_if_changed(path: str, content) -> bool:
    """Writes text (UTF-8) or bytes, unless the file already holds exactly that;
    returns whether it was written. Unchanged files keep their timestamp, so
    khamake and the Haxe server do not redo their work. The content is complete
    before the file is opened: a failure while making it leaves no partial file
    behind."""
    data = content.encode('utf-8') if isinstance(content, str) else bytes(content)
    if os.path.isfile(path):
        with open(path, 'rb') as f:
            if f.read() == data:
                return False
    with open(path, 'wb') as f:
        f.write(data)
    return True


def write_generated(path: str, content) -> bool:
    """write_if_changed() for a shader file that the build generates under a name
    it makes up. Writing different content under a name already written in this
    build fails the build. Otherwise two programs would share the file, and the
    last one written would silently replace the other."""
    import arm.viewport.context as context  # at call time: context is per build
    data = content.encode('utf-8') if isinstance(content, str) else bytes(content)
    key = os.path.normcase(os.path.abspath(path))
    digest = hashlib.sha1(data).digest()
    written = context.current().generated
    if written.setdefault(key, digest) != digest:
        raise RuntimeError('Viewport renderer: two different shaders named %s in one build (a name clash in '
                           "the renderer's shader names)" % os.path.basename(path))
    return write_if_changed(path, data)


def prune(folder: str, keep: set, owned=lambda name: True):
    """Deletes the files in `folder` that this build no longer uses: those that are
    `owned` (written by the renderer) and not in `keep`. The build folder is kept
    between builds, and compiled/Assets and compiled/Shaders are packed whole, so a
    stale file would ship with the game."""
    if not os.path.isdir(folder):
        return
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and owned(name) and name not in keep:
            os.remove(path)


def write_pass_data(name: str, texture_units: list, constants: list):
    """Writes and registers the shader data of a full-screen pass: the pixel
    shader `name`.frag over pass.vert, drawn into one RGBA64 image."""
    pass_data = {
        'name': name,
        'depth_write': False,
        'compare_mode': 'always',
        'cull_mode': 'none',
        'vertex_elements': [{'name': 'pos', 'data': 'float2'}],
        'color_attachments': ['RGBA64'],
        'vertex_shader': 'pass.vert',
        'fragment_shader': name + '.frag',
        'texture_units': texture_units,
        'constants': constants,
    }
    path = os.path.join(build_shaders(), name + '.arm')
    arm.utils.write_arm(path, {'shader_datas': [{'name': name, 'contexts': [pass_data]}]})
    assets.add_shader_data(path)
