"""The raster renderer's own build state and shader folder.

The shared package (arm.viewport) knows nothing about any one renderer. This
module keeps what only the raster renderer remembers during a build, and where
its shaders are. The state lives in the build context's slot for this renderer,
so it starts empty with every build.
"""
import arm
import arm.viewport.context as context
import arm.viewport.files as files

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    files = arm.reload_module(files)
else:
    arm.enable_reload(__name__)

SHADERS = 'vpraster'  # armory/Shaders/vpraster


def shaders(*parts: str) -> str:
    """A path under the raster renderer's shaders, armory/Shaders/vpraster."""
    return files.sdk_shaders(SHADERS, *parts)


class RasterBuild:
    def __init__(self):
        # materials
        self.shaders = {}           # shader name -> (shader data, its Samplers), see materials.write_shader()
        self.generation_key = None  # changes whenever a generated shader could change
        # mx_codegen: MaterialX library, generator and context, loaded once per build
        self.codegen = None
        # world
        self.extracted_suns = {}    # world name -> sun taken out of the world's light
        self.bakes = set()          # world bake base names (env_<world>_<key>)


def current() -> RasterBuild:
    """The raster renderer's state in the build in progress."""
    return context.current().renderer('raster', RasterBuild)
