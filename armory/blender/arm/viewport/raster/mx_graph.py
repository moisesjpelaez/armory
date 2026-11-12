"""Turns a material's MaterialX document (mx_export) into the material pass's document.

prepare() rebuilds the document with the material's exported surface replaced by
arm_gbuffer, arm_gbuffer_cutout or arm_gbuffer_blended
(Shaders/vpraster/materialx/arm_gbuffer.mtlx). These nodes pass the surface
values on to the material images, which the lighting pass reads, or to the
material's own shading (Render Method: Blended).

Blender exports:
  - a Principled BSDF as open_pbr_surface. Its inputs carry over by name.
  - Diffuse BSDF and Emission as a plain surface with an oren_nayar_diffuse_bsdf
    and/or a uniform_edf (whose colour is already multiplied by the strength).
    The diffuse colour becomes the base colour, with no specular, and the
    emission colour becomes the emission.

Which surface node a material gets (material_node()):
  - Dithered with alpha (opacity connected or below 1): arm_gbuffer_cutout.
  - Blended with alpha: arm_gbuffer_blended.
  - Blended without alpha: arm_gbuffer (OPAQUE_FORWARD). Eevee draws such a
    material opaque in its forward pass. Here it is lit by the lighting pass, but
    drawn at the point Eevee draws it, after the AOVs (see RasterTransparency).
  - Everything else: arm_gbuffer.

Two materials whose node graphs differ only in their surface values produce the
same canonical text, and so share a shader:
  - Nodes are renamed n0 (the surface), n1, ... in a fixed order.
  - Surface inputs that are not connected become uniforms. Their values go to
    the material, and the canonical text holds the defaults.
  - Texture file names are replaced by a placeholder. The shader has a sampler
    per image node, and each material binds its own file.
"""
import collections
from typing import NamedTuple

import MaterialX as mx

PLACEHOLDER_FILE = 'textures/bound_by_material'
SURFACE_NODE = 'n0'
SURFACES = ('open_pbr_surface', 'surface')

# OpenPBR inputs the material images do not hold, with the value that turns each
# off. A material that uses them renders without them, and they are reported as dropped.
NOT_IN_IMAGES = {
    'base_weight': '1', 'base_diffuse_roughness': '0', 'specular_roughness_anisotropy': '0',
    'transmission_weight': '0', 'subsurface_weight': '0', 'fuzz_weight': '0', 'coat_weight': '0',
    'thin_film_weight': '0', 'geometry_thin_walled': 'false',
}

# Eevee's surface classes. Eevee picks one from the material's Render Method and
# whether its surface has alpha (surface_class()). What each class draws is in
# materials.py (SURFACE_CLASSES).
DEFERRED = 'deferred'              # Dithered: writes the material images, lit by the lighting pass
OPAQUE_FORWARD = 'opaque_forward'  # Blended without alpha: Eevee draws it opaque, in its forward pass
BLENDED = 'blended'                # Blended with alpha: lit in its own shader, blended over the image


class Prepared:
    def __init__(self):
        self.text = ''            # canonical document
        self.surface_class = DEFERRED  # DEFERRED, OPAQUE_FORWARD or BLENDED
        self.problem = ''         # why the surface cannot be rendered, if it cannot
        self.values = {}          # surface input -> (MaterialX type, value string)
        self.textures = {}        # image node (canonical name) -> texture file name
        self.dropped = []         # inputs in use that the material images do not hold


class Source(NamedTuple):
    """What feeds one input of the material node: a node's output or a value."""
    connection: object  # the exported Input that a node is connected to, or None for a value
    value: str          # the value string, when nothing is connected


def exported(inp) -> Source:
    """The source that is an Input of the exported surface."""
    return Source(inp if inp.getConnectedNode() is not None else None, inp.getValueString())


def fixed(value: str) -> Source:
    """The source that is a value the exported surface does not have."""
    return Source(None, value)


def used(inp, off: str) -> bool:
    """Whether an input is connected or set to something other than `off`."""
    return inp is not None and (inp.getConnectedNode() is not None or inp.getValueString() != off)


def surface_sources(surface, result: Prepared) -> dict:
    """Material node input -> the Source feeding it. An input that is not listed
    keeps the material node's default."""
    sources = {}
    if surface.getCategory() == 'open_pbr_surface':
        for inp in surface.getInputs():
            name = 'opacity' if inp.getName() == 'geometry_opacity' else inp.getName()
            if name in NOT_IN_IMAGES:
                if used(inp, NOT_IN_IMAGES[name]):
                    result.dropped.append(name)
            else:
                sources[name] = exported(inp)
        return sources

    # Plain surface: Diffuse BSDF and/or Emission
    def carry(name: str, inp):
        if inp is not None:
            sources[name] = exported(inp)

    bsdf = surface.getInput('bsdf').getConnectedNode() if surface.getInput('bsdf') is not None else None
    edf = surface.getInput('edf').getConnectedNode() if surface.getInput('edf') is not None else None
    if bsdf is not None and bsdf.getCategory() != 'oren_nayar_diffuse_bsdf':
        result.problem = 'its %s is not supported' % bsdf.getCategory()
    if edf is not None and edf.getCategory() != 'uniform_edf':
        result.problem = 'its %s is not supported' % edf.getCategory()
    sources['specular_weight'] = fixed('0')
    if bsdf is None:
        sources['base_color'] = fixed('0, 0, 0')
    else:
        carry('base_color', bsdf.getInput('color'))
        carry('geometry_normal', bsdf.getInput('normal'))
        if used(bsdf.getInput('roughness'), '0'):
            result.dropped.append('diffuse roughness')
        if used(bsdf.getInput('weight'), '1'):
            result.dropped.append('diffuse weight')
    if edf is None:
        sources['emission_luminance'] = fixed('0')
    else:
        carry('emission_color', edf.getInput('color'))
        sources['emission_luminance'] = fixed('1')
    carry('opacity', surface.getInput('opacity'))
    return sources


def prepare(document_path: str, library, blended: bool = False) -> Prepared:
    """Reads a material's document and returns its canonical form for the material
    pass. `blended` is the material's Render Method: Blended. When the surface
    can't be rendered, only Prepared.problem is set."""
    # The exported document is kept until the end: its nodes are valid only while it exists
    exported_document, surface = exported_surface(document_path, library)
    result = Prepared()
    if surface.getCategory() not in SURFACES:
        result.problem = 'it is exported as %s' % surface.getCategory()
        return result
    sources = surface_sources(surface, result)
    if result.problem:
        return result

    alpha = has_alpha(sources)
    if not alpha:
        sources.pop('opacity', None)
    result.surface_class = surface_class(blended, alpha)
    gbuffer_def = library.getNodeDef(material_node(result.surface_class, alpha))
    order = node_order(gbuffer_def, sources)
    result.text = canonical_document(gbuffer_def, sources, order, result)
    return result


def exported_surface(document_path: str, library) -> tuple:
    """Reads an exported document. Returns (the document, its material's surface node)."""
    source = mx.createDocument()
    mx.readFromXmlFile(source, document_path)
    source.setDataLibrary(library)
    material = next((n for n in source.getNodes() if n.getCategory() == 'surfacematerial'), None)
    shader_input = material.getInput('surfaceshader') if material is not None else None
    surface = shader_input.getConnectedNode() if shader_input is not None else None
    if surface is None:
        raise RuntimeError('MaterialX document %s has no material with a surface' % document_path)
    return source, surface


def has_alpha(sources: dict) -> bool:
    """Whether the surface can be transparent: its opacity is connected or below 1."""
    opacity = sources.get('opacity')
    return opacity is not None and (opacity.connection is not None or float(opacity.value) < 1.0)


def surface_class(blended: bool, alpha: bool) -> str:
    """Eevee's surface class for a Render Method and a surface with or without alpha."""
    # Eevee blends a Blended material only if it can be transparent: its alpha is
    # linked or below 1 after Blender's constant folding, which the export applies
    # too (GPU_MATFLAG_TRANSPARENT in Blender). Otherwise Eevee draws it opaque in
    # its forward pass. It then hides and is hidden by other objects by depth, is
    # part of the Transparent pass, and does not cover the AOVs of what is behind it.
    if not blended:
        return DEFERRED
    return BLENDED if alpha else OPAQUE_FORWARD


def material_node(surface_class: str, alpha: bool) -> str:
    """The node definition of the material node that replaces the exported surface."""
    if surface_class == BLENDED:
        return 'ND_arm_gbuffer_blended'
    if surface_class == DEFERRED and alpha:
        return 'ND_arm_gbuffer_cutout'
    # Blended without alpha writes the material images like any opaque surface, so
    # the lighting pass lights it (RenderPathViewportRaster draws it after the AOVs)
    return 'ND_arm_gbuffer'


def node_order(gbuffer_def, sources: dict) -> list:
    """The exported nodes that feed the material node, in a fixed order whatever
    Blender named them: walking up from the material node's inputs, breadth first."""
    order, queue = [], collections.deque()
    for declared in gbuffer_def.getActiveInputs():
        source = sources.get(declared.getName())
        if source is not None and source.connection is not None:
            queue.append(source.connection.getConnectedNode())
    visited = set()
    while queue:
        node = queue.popleft()
        if node.getName() in visited:
            continue
        visited.add(node.getName())
        order.append(node)
        for inp in node.getInputs():
            if inp.getConnectedNode() is not None:
                queue.append(inp.getConnectedNode())
    return order


def canonical_document(gbuffer_def, sources: dict, order: list, result: Prepared) -> str:
    """Builds the material pass's document and returns its text. It holds the
    material node and copies of the nodes in `order`, renamed n1, n2, ... Fills
    result.values with the material's surface values and result.textures with its
    texture files."""
    doc = mx.createDocument()
    gbuffer = doc.addNode(gbuffer_def.getNodeString(), SURFACE_NODE, 'color4')
    gbuffer.setNodeDefString(gbuffer_def.getName())
    created = {}  # exported node name -> its copy
    for i, node in enumerate(order):
        copy = doc.addNode(node.getCategory(), 'n%d' % (i + 1), node.getType())
        if node.getNodeDefString():
            copy.setNodeDefString(node.getNodeDefString())
        for out in node.getOutputs():
            copy.addOutput(out.getName(), out.getType())
        created[node.getName()] = copy

    def connect(element, inp):
        element.setConnectedNode(created[inp.getConnectedNode().getName()])
        if inp.getOutputString():
            element.setOutputString(inp.getOutputString())

    for declared in gbuffer_def.getActiveInputs():
        name, mx_type = declared.getName(), declared.getType()
        source = sources.get(name)
        if source is None and declared.getDefaultGeomPropString():
            continue  # geometric defaults (normal, position) are left to MaterialX
        element = gbuffer.addInput(name, mx_type)
        if source is not None and source.connection is not None:
            connect(element, source.connection)
            continue
        # A surface value: the material sets it, and the document holds the default
        result.values[name] = (mx_type, source.value if source is not None else declared.getValueString())
        element.setValueString(declared.getValueString())

    for node in order:
        copy = created[node.getName()]
        for inp in node.getInputs():
            element = copy.addInput(inp.getName(), inp.getType())
            if inp.getConnectedNode() is not None:
                connect(element, inp)
            elif inp.getType() == 'filename':
                result.textures[copy.getName()] = inp.getValueString().split('/')[-1]
                element.setValueString(PLACEHOLDER_FILE)
                if inp.getColorSpace():
                    element.setColorSpace(inp.getColorSpace())
            else:
                element.setValueString(inp.getValueString())
                if inp.getColorSpace():
                    element.setColorSpace(inp.getColorSpace())

    doc.setVersionString('1.39')
    # Blender's scene-linear space. MaterialX converts textures tagged with another
    # colour space (such as srgb_texture) only when the document declares its own.
    doc.setColorSpace('lin_rec709')
    return mx.writeToXmlString(doc)
