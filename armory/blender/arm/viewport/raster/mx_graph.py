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

Which surface node a material gets:
  - Dithered with alpha (opacity connected or below 1): arm_gbuffer_cutout.
  - Blended with alpha: arm_gbuffer_blended.
  - Blended without alpha: arm_gbuffer (Prepared.opaque). Eevee draws such a
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


class Prepared:
    def __init__(self):
        self.text = ''            # canonical document
        self.cutout = False       # opacity in use: the surface node is arm_gbuffer_cutout
        self.blended = False      # Render Method: Blended (with alpha: the surface node is arm_gbuffer_blended)
        self.opaque = False       # Blended without alpha: arm_gbuffer, drawn after the AOVs (RasterTransparency)
        self.problem = ''         # why the surface cannot be rendered, if it cannot
        self.values = {}          # surface input -> (MaterialX type, value string)
        self.textures = {}        # image node (canonical name) -> texture file name
        self.dropped = []         # inputs in use that the material images do not hold


def used(inp, off: str) -> bool:
    """Whether an input is connected or set to something other than `off`."""
    return inp is not None and (inp.getConnectedNode() is not None or inp.getValueString() != off)


def surface_sources(surface, result: Prepared) -> dict:
    """Material node input -> the exported Input feeding it, or a fixed value string."""
    sources = {}
    if surface.getCategory() == 'open_pbr_surface':
        for inp in surface.getInputs():
            name = 'opacity' if inp.getName() == 'geometry_opacity' else inp.getName()
            if name in NOT_IN_IMAGES:
                if used(inp, NOT_IN_IMAGES[name]):
                    result.dropped.append(name)
            else:
                sources[name] = inp
        return sources

    # Plain surface: Diffuse BSDF and/or Emission
    bsdf = surface.getInput('bsdf').getConnectedNode() if surface.getInput('bsdf') is not None else None
    edf = surface.getInput('edf').getConnectedNode() if surface.getInput('edf') is not None else None
    if bsdf is not None and bsdf.getCategory() != 'oren_nayar_diffuse_bsdf':
        result.problem = 'its %s is not supported' % bsdf.getCategory()
    if edf is not None and edf.getCategory() != 'uniform_edf':
        result.problem = 'its %s is not supported' % edf.getCategory()
    sources['specular_weight'] = '0'
    if bsdf is None:
        sources['base_color'] = '0, 0, 0'
    else:
        sources['base_color'] = bsdf.getInput('color')
        if bsdf.getInput('normal') is not None:
            sources['geometry_normal'] = bsdf.getInput('normal')
        if used(bsdf.getInput('roughness'), '0'):
            result.dropped.append('diffuse roughness')
        if used(bsdf.getInput('weight'), '1'):
            result.dropped.append('diffuse weight')
    if edf is None:
        sources['emission_luminance'] = '0'
    else:
        sources['emission_color'] = edf.getInput('color')
        sources['emission_luminance'] = '1'
    if surface.getInput('opacity') is not None:
        sources['opacity'] = surface.getInput('opacity')
    return sources


def prepare(document_path: str, library, blended: bool = False) -> Prepared:
    """Reads a material's document and returns its canonical form for the material
    pass. `blended` is the material's Render Method: Blended. When the surface
    can't be rendered, only Prepared.problem is set."""
    source =mx.createDocument()
    mx.readFromXmlFile(source, document_path)
    source.setDataLibrary(library)
    material = next((n for n in source.getNodes() if n.getCategory() == 'surfacematerial'), None)
    shader_input = material.getInput('surfaceshader') if material is not None else None
    surface = shader_input.getConnectedNode() if shader_input is not None else None
    if surface is None:
        raise RuntimeError('MaterialX document %s has no material with a surface' % document_path)
    result = Prepared()
    if surface.getCategory() not in SURFACES:
        result.problem = 'it is exported as %s' % surface.getCategory()
        return result
    sources = surface_sources(surface, result)
    if result.problem:
        return result

    opacity = sources.get('opacity')
    cutout = opacity is not None and (opacity.getConnectedNode() is not None or float(opacity.getValueString()) < 1.0)
    # Eevee blends a Blended material only if it can be transparent: its alpha is
    # linked or below 1 after Blender's constant folding, which the export applies
    # too (GPU_MATFLAG_TRANSPARENT in Blender). Otherwise Eevee draws it opaque in
    # its forward pass. It then hides and is hidden by other objects by depth, is
    # part of the Transparent pass, and does not cover the AOVs of what is behind it.
    result.blended = blended
    result.opaque = blended and not cutout
    result.cutout = cutout and not blended
    if not cutout:
        sources.pop('opacity', None)
    # Blended without alpha writes the material images like any opaque surface, so
    # the lighting pass lights it (RenderPathViewportRaster draws it after the AOVs)
    node = ('ND_arm_gbuffer_blended' if result.blended and not result.opaque else
            'ND_arm_gbuffer_cutout' if result.cutout else 'ND_arm_gbuffer')
    gbuffer_def = library.getNodeDef(node)

    # Walk up from the surface's inputs, breadth first. This gives the nodes a fixed
    # order, whatever Blender named them.
    order, queue = [], collections.deque()
    for declared in gbuffer_def.getActiveInputs():
        inp = sources.get(declared.getName())
        if not isinstance(inp, str) and inp is not None and inp.getConnectedNode() is not None:
            queue.append(inp.getConnectedNode())
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
    names = {node.getName(): 'n%d' % (i + 1) for i, node in enumerate(order)}

    doc = mx.createDocument()
    gbuffer = doc.addNode(gbuffer_def.getNodeString(), SURFACE_NODE, 'color4')
    gbuffer.setNodeDefString(gbuffer_def.getName())
    created = {}
    for node in order:
        copy = doc.addNode(node.getCategory(), names[node.getName()], node.getType())
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
        name, kind = declared.getName(), declared.getType()
        inp = sources.get(name)
        if inp is None and declared.getDefaultGeomPropString():
            continue  # geometric defaults (normal, position) are left to MaterialX
        element = gbuffer.addInput(name, kind)
        if not isinstance(inp, str) and inp is not None and inp.getConnectedNode() is not None:
            connect(element, inp)
            continue
        value = inp if isinstance(inp, str) else inp.getValueString() if inp is not None else declared.getValueString()
        result.values[name] = (kind, value)
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
    result.text = mx.writeToXmlString(doc)
    return result
