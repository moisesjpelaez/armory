"""A material's MaterialX document (mx_export) as the material pass's document.

prepare() rebuilds the document with the material's exported surface replaced
by arm_gbuffer or arm_gbuffer_cutout (Shaders/eevee/materialx/arm_gbuffer.mtlx),
which write the surface values to the material images the lighting pass reads.
Blender exports:
  - a Principled BSDF as open_pbr_surface: its inputs carry over by name
  - Diffuse BSDF and Emission as a plain surface with an oren_nayar_diffuse_bsdf
    and/or a uniform_edf (emission colour already times strength): the diffuse
    colour is the base colour with no specular, the emission colour the emission
Materials with alpha (opacity connected or below 1) get arm_gbuffer_cutout.

Two materials whose node graphs differ only in their surface values produce the
same canonical text, hence share a shader:
  - nodes are renamed n0 (the surface), n1, ... in a fixed order
  - surface inputs that are not connected are uniforms: their values go to the
    material, the canonical text holds the defaults
  - texture file names are replaced by a placeholder: the shader has a sampler
    per image node, each material binds its own file
"""
import MaterialX as mx

PLACEHOLDER_FILE = 'textures/bound_by_material'
SURFACE_NODE = 'n0'
SURFACES = ('open_pbr_surface', 'surface')

# OpenPBR inputs the material images do not hold yet, with the value that turns
# them off: a material using them renders without them (reported as dropped)
NOT_IN_IMAGES = {
    'base_weight': '1', 'base_diffuse_roughness': '0', 'specular_roughness_anisotropy': '0',
    'transmission_weight': '0', 'subsurface_weight': '0', 'fuzz_weight': '0', 'coat_weight': '0',
    'thin_film_weight': '0', 'geometry_thin_walled': 'false',
}


class Prepared:
    def __init__(self):
        self.text = ''            # canonical document
        self.category = ''        # the exported surface's node category
        self.problem = ''         # why the surface cannot be rendered, if it cannot
        self.values = {}          # surface input -> (MaterialX type, value string)
        self.textures = {}        # image node (canonical name) -> texture file name
        self.dropped = []         # inputs in use that the material images do not hold


def used(inp, off: str) -> bool:
    return inp is not None and (inp.getConnectedNode() is not None or inp.getValueString() != off)


def surface_sources(surface, result: Prepared) -> dict:
    """Material node input -> the exported Input feeding it, or a fixed value string."""
    sources = {}
    if result.category == 'open_pbr_surface':
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
        result.problem = 'its %s is not supported yet' % bsdf.getCategory()
    if edf is not None and edf.getCategory() != 'uniform_edf':
        result.problem = 'its %s is not supported yet' % edf.getCategory()
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


def prepare(document_path: str, library) -> Prepared:
    source = mx.createDocument()
    mx.readFromXmlFile(source, document_path)
    source.setDataLibrary(library)
    material = next(n for n in source.getNodes() if n.getCategory() == 'surfacematerial')
    surface = material.getInput('surfaceshader').getConnectedNode()
    result = Prepared()
    result.category = surface.getCategory()
    if result.category not in SURFACES:
        result.problem = 'it is exported as %s' % result.category
        return result
    sources = surface_sources(surface, result)
    if result.problem:
        return result

    opacity = sources.get('opacity')
    cutout = opacity is not None and (opacity.getConnectedNode() is not None or float(opacity.getValueString()) < 1.0)
    if not cutout:
        sources.pop('opacity', None)
    gbuffer_def = library.getNodeDef('ND_arm_gbuffer_cutout' if cutout else 'ND_arm_gbuffer')

    # Walk up from the surface's inputs: a fixed order whatever Blender named the nodes
    order, queue = [], []
    for declared in gbuffer_def.getActiveInputs():
        inp = sources.get(declared.getName())
        if not isinstance(inp, str) and inp is not None and inp.getConnectedNode() is not None:
            queue.append(inp.getConnectedNode())
    while queue:
        node = queue.pop(0)
        if node.getName() in (n.getName() for n in order):
            continue
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
    # Blender's scene-linear space: MaterialX converts textures tagged with another
    # colour space (srgb_texture) only when the document declares its own
    doc.setColorSpace('lin_rec709')
    result.text = mx.writeToXmlString(doc)
    return result
