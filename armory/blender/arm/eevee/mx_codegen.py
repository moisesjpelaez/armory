"""MaterialX -> GLSL for the Eevee renderer's material pass, using the MaterialX
that ships with Blender.

Shaders are generated with a reduced interface (only nodedef inputs stay
uniforms, everything else is baked in), with arm_gbuffer from
Shaders/eevee/materialx as the surface. They light nothing: the lighting pass
is our own GLSL (lighting.py). MaterialX's "lights" library is left out.
"""
import os

import MaterialX as mx
import MaterialX.PyMaterialXGenGlsl as mx_glsl
import MaterialX.PyMaterialXGenShader as mx_gen

LIBRARY_FOLDERS = ('targets', 'stdlib', 'pbrlib', 'bxdf', 'cmlib', 'nprlib')

_cache = {}


def version() -> str:
    return mx.getVersionString()


def _generator(data_dir: str):
    """Library, generator and context are built once per data folder."""
    if data_dir in _cache:
        return _cache[data_dir]

    library = mx.createDocument()
    mx.loadLibraries(['libraries/' + name for name in LIBRARY_FOLDERS], mx.getDefaultDataSearchPath(), library)
    mx.readFromXmlFile(library, os.path.join(data_dir, 'arm_gbuffer.mtlx'))

    generator = mx_glsl.GlslShaderGenerator.create()
    context = mx_gen.GenContext(generator)
    context.registerSourceCodeSearchPath(mx.getDefaultDataSearchPath())
    context.registerSourceCodeSearchPath(mx.FileSearchPath(data_dir))
    # Shaders/eevee: MaterialX resolves arm_gbuffer.glsl's #include "eevee_common.inc" itself
    context.registerSourceCodeSearchPath(mx.FileSearchPath(os.path.dirname(data_dir)))
    generator.registerTypeDefs(library)

    options = context.getOptions()
    options.shaderInterfaceType = mx_gen.SHADER_INTERFACE_REDUCED
    options.hwSrgbEncodeOutput = False  # the film pass owns the display transform
    options.targetDistanceUnit = 'meter'

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

    _cache[data_dir] = (library, generator, context)
    return _cache[data_dir]


def reset():
    """Forgets the loaded library and generator (arm_gbuffer.mtlx may have changed)."""
    _cache.clear()


def library(data_dir: str):
    """MaterialX's node library (with arm_gbuffer), loaded once."""
    return _generator(data_dir)[0]


def generate_fragment(data_dir: str, document_path: str, shader_name: str, element_name: str = None) -> str:
    """Generates the pixel shader for a .mtlx document.

    With a reduced interface only the inputs of the generated element's nodedef
    stay uniforms, so pass `element_name` to generate for a surface node whose
    inputs should be adjustable; otherwise the first renderable element is used.
    """
    library, generator, context = _generator(data_dir)
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
    shader = generator.generate(shader_name, element, context)
    if shader is None:
        raise RuntimeError('MaterialX could not generate %s' % document_path)
    return shader.getSourceCode(mx_gen.PIXEL_STAGE)
