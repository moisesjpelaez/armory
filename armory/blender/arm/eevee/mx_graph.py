"""A material's MaterialX document (mx_export) as the material pass's document.

prepare() rebuilds the document with the material's open_pbr_surface replaced
by arm_gbuffer (Shaders/eevee/materialx/arm_gbuffer.mtlx), which writes the
surface values to the material images that the lighting pass reads. Two
materials whose node graphs differ only in their surface values produce the same
canonical text, hence share a shader:
  - nodes are renamed n0, n1, ... in a fixed order (walking up from the surface)
  - surface inputs that are not connected (or not set by Blender) stay on the
    surface node, so MaterialX's reduced interface publishes them as uniforms;
    their values go to the material, the canonical text holds the defaults
  - texture file names are replaced by a placeholder: the shader has a sampler
    per image node, each material binds its own file
"""
import MaterialX as mx

PLACEHOLDER_FILE = 'textures/bound_by_material'
SURFACE = 'arm_gbuffer'
SURFACE_NODE = 'n0'  # the surface is the first node of the walk

# OpenPBR inputs the material images do not hold yet, with the value that turns
# them off: a material using them renders without them (reported as dropped)
NOT_IN_IMAGES = {
    'base_weight': '1', 'base_diffuse_roughness': '0', 'specular_roughness_anisotropy': '0',
    'transmission_weight': '0', 'subsurface_weight': '0', 'fuzz_weight': '0', 'coat_weight': '0',
    'thin_film_weight': '0', 'geometry_opacity': '1', 'geometry_thin_walled': 'false',
}


class Prepared:
    def __init__(self):
        self.text = ''            # canonical document
        self.category = ''        # the exported surface's node category (open_pbr_surface for a Principled BSDF)
        self.values = {}          # surface input -> (MaterialX type, value string)
        self.textures = {}        # image node (canonical name) -> texture file name
        self.dropped = []         # OpenPBR inputs in use that the material images do not hold


def prepare(document_path: str, library) -> Prepared:
    source = mx.createDocument()
    mx.readFromXmlFile(source, document_path)
    source.setDataLibrary(library)
    material = next(n for n in source.getNodes() if n.getCategory() == 'surfacematerial')
    surface = material.getInput('surfaceshader').getConnectedNode()
    result = Prepared()
    result.category = surface.getCategory()
    if result.category != 'open_pbr_surface':
        return result

    gbuffer_def = library.getNodeDef('ND_arm_gbuffer')

    # Walk up from the surface (through the inputs arm_gbuffer keeps): a fixed
    # order whatever Blender named the nodes
    order, queue = [], [surface]
    while queue:
        node = queue.pop(0)
        if node.getName() in (n.getName() for n in order):
            continue
        order.append(node)
        for inp in node.getInputs():
            upstream = inp.getConnectedNode()
            if upstream is not None and (node is not surface or gbuffer_def.getActiveInput(inp.getName()) is not None):
                queue.append(upstream)
    names = {node.getName(): 'n%d' % i for i, node in enumerate(order)}

    doc = mx.createDocument()
    created = {}
    for node in order:
        if node is surface:
            copy = doc.addNode(SURFACE, names[node.getName()], 'color4')
            copy.setNodeDefString(gbuffer_def.getName())
        else:
            copy = doc.addNode(node.getCategory(), names[node.getName()], node.getType())
            if node.getNodeDefString():
                copy.setNodeDefString(node.getNodeDefString())
            for out in node.getOutputs():
                copy.addOutput(out.getName(), out.getType())
        created[node.getName()] = copy

    for node in order:
        copy = created[node.getName()]
        for inp in node.getInputs():
            upstream = inp.getConnectedNode()
            if node is surface:
                if gbuffer_def.getActiveInput(inp.getName()) is None:
                    off = NOT_IN_IMAGES.get(inp.getName())
                    if off is not None and (upstream is not None or inp.getValueString() != off):
                        result.dropped.append(inp.getName())
                    continue
                element = copy.addInput(inp.getName(), inp.getType())
                if upstream is None:
                    result.values[inp.getName()] = (inp.getType(), inp.getValueString())
                    element.setValueString(gbuffer_def.getActiveInput(inp.getName()).getValueString())
                    continue
            else:
                element = copy.addInput(inp.getName(), inp.getType())
            if upstream is not None:
                element.setConnectedNode(created[upstream.getName()])
                if inp.getOutputString():
                    element.setOutputString(inp.getOutputString())
            elif inp.getType() == 'filename':
                result.textures[copy.getName()] = inp.getValueString().split('/')[-1]
                element.setValueString(PLACEHOLDER_FILE)
                if inp.getColorSpace():
                    element.setColorSpace(inp.getColorSpace())
            else:
                element.setValueString(inp.getValueString())
                if inp.getColorSpace():
                    element.setColorSpace(inp.getColorSpace())

    # Inputs Blender left unset are uniforms too, bound to their default
    # (geometric defaults such as the normal are left to MaterialX)
    surface_copy = created[surface.getName()]
    for declared in gbuffer_def.getActiveInputs():
        name = declared.getName()
        if surface_copy.getInput(name) is not None or declared.getDefaultGeomPropString():
            continue
        result.values[name] = (declared.getType(), declared.getValueString())
        surface_copy.addInput(name, declared.getType()).setValueString(declared.getValueString())

    doc.setVersionString('1.39')
    # Blender's scene-linear space: MaterialX converts textures tagged with another
    # colour space (srgb_texture) only when the document declares its own
    doc.setColorSpace('lin_rec709')
    result.text = mx.writeToXmlString(doc)
    return result
