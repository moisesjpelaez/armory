"""Everything the Viewport renderer remembers during one build.

make.export_data() calls begin() before the world, render path and scene
exports. Every build module then reads and fills current(). Nothing outlives
the build. So the next build gives its warnings again and picks up edits to the
renderer's own files.
"""
import arm

if not arm.is_reload(__name__):
    arm.enable_reload(__name__)


class BuildContext:
    def __init__(self):
        # mx_export, mx_extract
        self.documents = {}         # material name -> MaterialX document path
        self.default_document = None  # Blender's default material (objects without one)
        self.nodedefs = None        # MaterialX node definitions by name, loaded on the first export
        self.aov_documents = {}     # material hash -> {AOV name: (type, document path)}
        self.aov_types = {}         # AOV name -> 'COLOR' or 'VALUE' (the first scene declaring it)
        self.material_hashes = {}   # (material pointer, full name) -> its hash (mx_export.material_hash)
        self.group_signatures = {}  # (node group pointer, full name) -> its signature (signature.tree_signature)
        self.reported = set()       # (topic, material) already warned about
        self.generated = {}         # generated shader file -> hash of its content (files.write_generated)
        self.renderers = {}         # renderer name -> its own state (e.g. raster/state.py)

    def renderer(self, name: str, make):
        """A renderer's own state in this build, made by `make()` the first time."""
        if name not in self.renderers:
            self.renderers[name] = make()
        return self.renderers[name]


_current = None


def begin() -> BuildContext:
    global _current
    _current = BuildContext()
    return _current


def current() -> BuildContext:
    if _current is None:
        raise RuntimeError('Viewport renderer: no build in progress (viewport.context.begin() not called)')
    return _current


def exported_scenes() -> list:
    """The scenes this build exports, chosen as make.export_data() chooses them.
    A scene must have Export on and be part of the project (local, or linked from
    the external blends path). Library scenes that add-ons bring in are left out."""
    import bpy
    from arm import make  # at call time: arm.make imports the renderer's modules
    return [scene for scene in bpy.data.scenes if scene.arm_export and make.is_project_scene(scene)]


def warn_once(topic: str, name: str) -> bool:
    """True the first time `topic` is reported for `name` in this build."""
    key = (topic, name)
    if key in current().reported:
        return False
    current().reported.add(key)
    return True
