"""Everything the Eevee renderer remembers during one build.

make.export_data() starts a build with begin() before the world, render path
and scene exports; every build module then reads and fills current(). Nothing
outlives the build: warnings are given again, and edits to the renderer's own
files are picked up, on the next build.
"""
import arm

if not arm.is_reload(__name__):
    arm.enable_reload(__name__)


class BuildContext:
    def __init__(self):
        # mx_export
        self.documents = {}         # material name -> MaterialX document path
        self.default_document = None  # Blender's default material (objects without one)
        self.nodedefs = None        # MaterialX node definitions by name, loaded on the first export
        # materials
        self.shaders = {}           # shader name -> (shader data, {image node: sampler uniform})
        self.generation_key = None  # changes whenever a generated shader could change
        self.reported = set()       # (topic, material) already warned about
        # mx_codegen: MaterialX library, generator and context, loaded once per build
        self.codegen = None
        # world
        self.extracted_suns = {}    # world name -> sun taken out of the world's light
        self.bakes = set()          # world bake base names (env_<world>_<key>)


_current = None


def begin() -> BuildContext:
    global _current
    _current = BuildContext()
    return _current


def current() -> BuildContext:
    if _current is None:
        raise RuntimeError('Eevee renderer: no build in progress (eevee.context.begin() not called)')
    return _current


def warn_once(topic: str, name: str) -> bool:
    """True the first time `topic` is reported for `name` in this build."""
    key = (topic, name)
    if key in current().reported:
        return False
    current().reported.add(key)
    return True
