"""Folders and file writes shared by the Viewport renderer's build modules."""
import os

import arm
import arm.utils

if arm.is_reload(__name__):
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)


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
    import hashlib
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
    `owned` (written by the renderer) and not in `keep`. compiled/Assets is packed
    whole, so a stale file would ship with the game."""
    if not os.path.isdir(folder):
        return
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and owned(name) and name not in keep:
            os.remove(path)


def resolve(template: str, flags: set, defines: dict = None) -> str:
    """The shader template at path `template`, with the renderer's options applied:
      - its #include "..." lines (files next to it) are inlined
      - #ifdef / #ifndef / #else / #endif on ARM_ names are evaluated against `flags`
      - `defines` (name -> value) are written after #version
    Other directives are left to the shader compiler. The result is exactly what
    gets compiled, so its inputs and uniforms can be read from it."""
    with open(template, encoding='utf-8') as f:
        lines = f.read().split('\n')
    out = []
    stack = []  # per open #if: (on an ARM_ name, branch taken)

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
            out.append(resolve(os.path.join(os.path.dirname(template), words[1].strip('"')), flags))
            continue
        out.append(line)
        if directive == '#version' and defines:
            out += ['#define %s %s' % item for item in defines.items()]
    if stack:
        raise RuntimeError('Viewport renderer: unterminated #if in %s' % os.path.basename(template))
    return '\n'.join(out)
