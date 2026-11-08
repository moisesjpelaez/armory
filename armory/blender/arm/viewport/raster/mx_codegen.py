"""MaterialX -> GLSL for the Viewport renderer's material pass, using the MaterialX
that ships with Blender.

Shaders are generated with a reduced interface (only nodedef inputs stay
uniforms, everything else is baked in), with arm_gbuffer from
Shaders/vpraster/materialx as the surface. They light nothing: the lighting pass
is our own GLSL (lighting.py). MaterialX's "lights" library is left out.
"""
import os

import MaterialX as mx
import MaterialX.PyMaterialXGenGlsl as mx_glsl
import MaterialX.PyMaterialXGenShader as mx_gen

import arm
import arm.viewport.raster.state as state

if arm.is_reload(__name__):
    state = arm.reload_module(state)
else:
    arm.enable_reload(__name__)

LIBRARY_FOLDERS = ('targets', 'stdlib', 'pbrlib', 'bxdf', 'cmlib', 'nprlib')


def version() -> str:
    return mx.getVersionString()


def _generator(data_dir: str):
    """Library, generator and generation context, built once per build."""
    ctx = state.current()
    if ctx.codegen is not None:
        return ctx.codegen

    library = mx.createDocument()
    mx.loadLibraries(['libraries/' + name for name in LIBRARY_FOLDERS], mx.getDefaultDataSearchPath(), library)
    mx.readFromXmlFile(library, os.path.join(data_dir, 'arm_gbuffer.mtlx'))

    generator = mx_glsl.GlslShaderGenerator.create()
    gen_context = mx_gen.GenContext(generator)
    gen_context.registerSourceCodeSearchPath(mx.getDefaultDataSearchPath())
    gen_context.registerSourceCodeSearchPath(mx.FileSearchPath(data_dir))
    # Shaders/vpraster: MaterialX resolves arm_gbuffer.glsl's #include "vpraster_common.inc" itself
    gen_context.registerSourceCodeSearchPath(mx.FileSearchPath(os.path.dirname(data_dir)))
    generator.registerTypeDefs(library)

    options = gen_context.getOptions()
    options.shaderInterfaceType = mx_gen.SHADER_INTERFACE_REDUCED
    options.hwSrgbEncodeOutput = False  # the film pass owns the display transform
    options.targetDistanceUnit = 'meter'
    # Texture coordinates are Blender's (vertex.py); images start at the top in Kha
    options.fileTextureVerticalFlip = True

    color_management = mx_gen.DefaultColorManagementSystem.create(generator.getTarget())
    color_management.loadLibrary(library)
    generator.setColorManagementSystem(color_management)
    units = mx_gen.UnitSystem.create(generator.getTarget())
    registry = mx.UnitConverterRegistry.create()
    for unit in ('distance', 'angle'):
        typedef = library.getUnitTypeDef(unit)
        registry.addUnitConverter(typedef, mx.LinearUnitConverter.create(typedef))
    units.loadLibrary(library)
    units.setUnitConverterRegistry(registry)
    generator.setUnitSystem(units)

    ctx.codegen = (library, generator, gen_context)
    return ctx.codegen


def library(data_dir: str):
    """MaterialX's node library (with arm_gbuffer), loaded once per build."""
    return _generator(data_dir)[0]


def generate_fragment(data_dir: str, document_path: str, shader_name: str, element_name: str = None) -> str:
    """Generates the pixel shader for a .mtlx document.

    With a reduced interface only the inputs of the generated element's nodedef
    stay uniforms, so pass `element_name` to generate for a surface node whose
    inputs should be adjustable; otherwise the first renderable element is used.
    """
    library, generator, gen_context = _generator(data_dir)
    doc = mx.createDocument()
    mx.readFromXmlFile(doc, document_path)
    doc.setDataLibrary(library)
    valid, message = doc.validate()
    if not valid:
        raise RuntimeError('MaterialX document %s is invalid: %s' % (document_path, message))
    if element_name is not None:
        element = doc.getChild(element_name)
    else:
        elements = mx_gen.findRenderableElements(doc)
        element = elements[0] if elements else None
    if element is None:
        raise RuntimeError('MaterialX document %s has no renderable element' % document_path)
    shader = generator.generate(shader_name, element, gen_context)
    if shader is None:
        raise RuntimeError('MaterialX could not generate %s' % document_path)
    return shader.getSourceCode(mx_gen.PIXEL_STAGE)
