"""Library hooks: what a library's `armory_hooks.py` (in Libraries/ or
Subprojects/) can add to Armory. All functions are optional:

    write_main()              Main.hx and khafile.js additions (write_data.py)
    runtimes(), targets()     Extra Runtime / exporter Target list entries:
                              [(id, name, description[, number]), ...]
    owns_build(request)       True if the library builds this request itself
    compile(request, done)    That build, instead of Armory's khamake compile;
                              calls done(success) at the end
    clean(request)            Publish's clean for that build
    clean_project()           Clean Project, before Armory deletes the build
                              folders (every library's, whatever the target)

Builds for library entries export Kha's 'custom' target.
"""
import importlib.util
import os
import zlib
from typing import Callable, List, Optional, Tuple

import bpy

import arm
import arm.log as log
import arm.make_state as state

if arm.is_reload(__name__):
    log = arm.reload_module(log)
    state = arm.reload_module(state)
else:
    arm.enable_reload(__name__)


# Armory's own list entries (Blender saves a choice as its position here)
BUILTIN_RUNTIMES = [('Krom', 'Krom', 'Krom'),
                    ('Browser', 'Browser', 'Browser')]

BUILTIN_TARGETS = [('html5', 'HTML5 (JS)', 'html5'),
                   ('windows-hl', 'Windows (C)', 'windows-hl'),
                   ('windows', 'Windows (C++)', 'windows'),
                   ('krom-windows', 'Windows (Krom)', 'krom-windows'),
                   ('macos-hl', 'macOS (C)', 'macos-hl'),
                   ('krom-macos', 'macOS (Krom)', 'krom-macos'),
                   ('linux-hl', 'Linux (C)', 'linux-hl'),
                   ('krom-linux', 'Linux (Krom)', 'krom-linux'),
                   ('ios-hl', 'iOS (C)', 'ios-hl'),
                   ('android-hl', 'Android (C)', 'android-hl'),
                   ('node', 'Node (JS)', 'node'),
                   ('custom', 'Custom', 'custom')]

# A library entry without a number gets one from its id, after Armory's
FIRST_LIBRARY_NUMBER = 1000
LIBRARY_NUMBER_RANGE = 1000000


# Build requests

class BuildRequest:
    """What is being built."""

    def __init__(self, target: str, is_play: bool, is_publish: bool, is_export: bool,
                 runtime: str, exporter_target: Optional[str]):
        self.target = target                    # Kha target exported
        self.is_play = is_play
        self.is_publish = is_publish
        self.is_export = is_export
        self.runtime = runtime                  # Runtime list choice
        self.exporter_target = exporter_target  # Target list choice when exporting, else None

    @staticmethod
    def current() -> 'BuildRequest':
        """The build make.build() started."""
        wrd = bpy.data.worlds['Arm']
        exporter_target = None
        if state.is_export and len(wrd.arm_exporterlist) > 0:
            exporter_target = wrd.arm_exporterlist[wrd.arm_exporterlist_index].arm_project_target
        return BuildRequest(state.target, state.is_play, state.is_publish, state.is_export,
                            wrd.arm_runtime, exporter_target)


# Loading the hook files

# Hook file -> (modification time, library name, module)
_loaded = {}


def hook_modules() -> List[Tuple[str, object]]:
    """(library name, module) of every armory_hooks.py of the project."""
    modules = []
    for lib, hook_file in _hook_files():
        module = _load(lib, hook_file)
        if module is not None:
            modules.append((lib, module))
    return modules


def _hook_files() -> List[Tuple[str, str]]:
    """(library name, path) of the project's armory_hooks.py files."""
    import arm.utils
    try:
        project = arm.utils.get_fp()
    except Exception:  # No 'Arm' world yet, while Blender loads a file
        return []
    files = []
    for folder in ('Libraries', 'Subprojects'):
        root = os.path.join(project, folder) if project else ''
        if os.path.isdir(root):
            for lib in os.listdir(root):
                hook_file = os.path.join(root, lib, 'armory_hooks.py')
                if os.path.isfile(hook_file):
                    files.append((lib, hook_file))
    return files


def _load(lib: str, hook_file: str):
    """The module of a hook file, loaded again only when the file changed."""
    mtime = os.path.getmtime(hook_file)
    cached = _loaded.get(hook_file)
    if cached is not None and cached[0] == mtime:
        return cached[2]
    try:
        spec = importlib.util.spec_from_file_location(f'armory_hooks_{lib}', hook_file)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as e:
        log.warn(f'Failed to load hook from {lib}: {e}')
        _loaded.pop(hook_file, None)
        return None
    _loaded[hook_file] = (mtime, lib, module)
    return module


def _call(lib: str, module, name: str, *args, default=None):
    """A hook function's result: default if the library doesn't define it or it fails."""
    func = getattr(module, name, None)
    if func is None:
        return default
    try:
        return func(*args)
    except Exception as e:
        log.warn(f'Library hook {lib}.{name}() failed: {e}')
        return default


# Runtime and Target lists

# The items last given to Blender (it needs their strings kept alive), and
# the ids libraries added
_items = {}
_library_ids = {'runtimes': set(), 'targets': set()}
_reported = set()


def runtime_items(self, context) -> list:
    """Items of the Runtime list (World.arm_runtime)."""
    return _list_items('runtimes', BUILTIN_RUNTIMES)


def target_items(self, context) -> list:
    """Items of the exporter's Target list (ArmExporterListItem.arm_project_target)."""
    return _list_items('targets', BUILTIN_TARGETS)


def is_library_runtime(runtime: str) -> bool:
    return _is_library_entry('runtimes', BUILTIN_RUNTIMES, runtime)


def is_library_target(target: str) -> bool:
    return _is_library_entry('targets', BUILTIN_TARGETS, target)


def build_target(exporter_target: str) -> str:
    """Kha target exported for a Target list choice."""
    return 'custom' if is_library_target(exporter_target) else exporter_target


def _is_library_entry(kind: str, builtin: list, id: str) -> bool:
    if any(entry[0] == id for entry in builtin):
        return False
    _list_items(kind, builtin)
    return id in _library_ids[kind]


def _list_items(kind: str, builtin: list) -> list:
    """Armory's entries, then the libraries'."""
    items = [(id, name, desc, number) for number, (id, name, desc) in enumerate(builtin)]
    added = set()
    for lib, module in hook_modules():
        for entry in _call(lib, module, kind, default=[]):
            item = _library_item(entry)
            problem = _clash(item, items)
            if problem:
                _error_once(f'Library {lib}: {problem} in the {kind[:-1]} list, entry ignored')
            else:
                items.append(item)
                added.add(item[0])
    _items[kind] = items
    _library_ids[kind] = added
    return items


def _library_item(entry) -> tuple:
    """(id, name, description, number) of a library's entry."""
    id, name, desc = entry[:3]
    if len(entry) > 3:
        number = entry[3]
    else:
        number = FIRST_LIBRARY_NUMBER + zlib.crc32(id.encode()) % LIBRARY_NUMBER_RANGE
    return (id, name, desc, number)


def _clash(item: tuple, items: list) -> Optional[str]:
    """What another entry already uses of this one: its id or its number."""
    for other in items:
        if other[0] == item[0]:
            return f'"{item[0]}" is already there'
        if other[3] == item[3]:
            return f'number {item[3]} of "{item[0]}" is already used by "{other[0]}"'
    return None


def _error_once(message: str):
    """Lists are rebuilt on every draw: report each problem once."""
    if message not in _reported:
        _reported.add(message)
        log.error(message)


# Builds

CONFLICT = object()


def build_owner(request: BuildRequest):
    """(library name, module) of the library building this request; None if
    Armory builds it; CONFLICT if several libraries claim it (reported)."""
    owners = [(lib, module) for lib, module in hook_modules()
              if _call(lib, module, 'owns_build', request, default=False)]
    if len(owners) > 1:
        log.error(f'Libraries {", ".join(lib for lib, _ in owners)} all build this request: remove all but one')
        return CONFLICT
    return owners[0] if owners else None


def compile(owner, request: BuildRequest, done: Callable[[bool], None]):
    """Hand the build to the library owning it."""
    lib, module = owner
    log.info(f'Building with library {lib}')
    try:
        module.compile(request, done)
    except Exception as e:
        import traceback
        traceback.print_exc()
        log.error(f'Library {lib} failed to build: {e}')
        done(False)


def clean_project():
    """Every library's clean_project(), before Clean Project deletes the build folders."""
    for lib, module in hook_modules():
        _call(lib, module, 'clean_project')


def clean(request: BuildRequest) -> bool:
    """The owning library's clean before a Publish; False if Armory cleans."""
    owner = build_owner(request)
    if owner is None or owner is CONFLICT or not hasattr(owner[1], 'clean'):
        return False
    _call(owner[0], owner[1], 'clean', request)
    return True
