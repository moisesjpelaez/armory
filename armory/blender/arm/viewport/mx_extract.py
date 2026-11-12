"""Blender's USD export -> one standalone MaterialX document per material (Viewport renderer).

Blender's USD exporter writes each material as a MaterialX network of USD
Shader prims. mx_export.export() runs the exporter and hands the USD stage to
extract(), which:
  - rebuilds each wanted material's network as a MaterialX document (Extractor),
  - puts back the blend modes of colour Mix nodes, which Blender exports as a
    plain mix (restore_blend_modes()),
  - copies the material's textures next to the game's assets, named after their
    content. An image that Blender could not export is replaced by a magenta
    one, as Eevee draws it (missing_image()).
"""
import os
import re
import shutil
import struct
import zlib

import arm
import arm.viewport.context as context
import arm.viewport.files as files
import arm.viewport.mx_report as mx_report
import arm.log as log

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    mx_report = arm.reload_module(mx_report)
    log = arm.reload_module(log)
else:
    arm.enable_reload(__name__)

# An image that Blender could not export is drawn with MISSING_IMAGE (missing_image()).
# Its document keeps the image's name in the MISSING_ATTRIBUTE attribute (report_missing_images()).
MISSING_IMAGE = 'viewport_missing_image.png'
MISSING_ATTRIBUTE = 'arm_missing'

VERSIONED_ID = re.compile(r'^(.*)_(\d+)_(\d+)$')
OPAQUE_TYPES = {'BSDF', 'EDF', 'VDF', 'surfaceshader', 'displacementshader', 'volumeshader',
                'lightshader', 'material'}


def nodedefs() -> dict:
    """MaterialX's node definitions by name, loaded once per build."""
    ctx = context.current()
    if ctx.nodedefs is None:
        import MaterialX as mx
        library = mx.createDocument()
        mx.loadLibraries(mx.getDefaultDataLibraryFolders(), mx.getDefaultDataSearchPath(), library)
        ctx.nodedefs = {nd.getName(): nd for nd in library.getNodeDefs()}
    return ctx.nodedefs


def extract(stage, node_definitions: dict, wanted: dict, usd_folder: str, texture_folder: str):
    """Writes the documents of the `wanted` materials (name -> (material, .mtlx
    path)) found in the stage, and removes them from `wanted`. `node_definitions`
    is nodedefs(). `usd_folder` is where Blender exported the stage and its
    textures, and the textures in use are copied to `texture_folder`."""
    import MaterialX as mx
    for prim in stage.Traverse():
        if not wanted:
            break
        if prim.GetTypeName() != 'Material' or surface_property(prim) is None:
            continue
        name = blender_name(prim)
        if name not in wanted:
            continue
        material, path = wanted.pop(name)
        extractor = Extractor(stage, node_definitions, mx_report.display_name(material))
        doc = extractor.extract(prim)
        for reason, detail in extractor.dropped:
            log.warn('Viewport renderer: material "%s": %s %s' % (mx_report.display_name(material), reason, detail))
        restore_blend_modes(doc, material)
        copy_textures(extractor.textures, usd_folder, texture_folder)
        mx.writeToXmlFile(doc, path)


def copy_textures(textures: list, usd_folder: str, texture_folder: str):
    """Copies a document's textures from Blender's export to `texture_folder`, and
    points the document at the copies. `textures` is Extractor.textures."""
    for texture, element in textures:
        source = os.path.join(usd_folder, texture)
        if not os.path.isfile(source):
            # Blender found nothing to export (a missing or unreadable file). Eevee
            # draws such an image magenta. It is reported on every build
            # (report_missing_images()).
            element.setValueString('textures/' + missing_image(texture_folder))
            element.setAttribute(MISSING_ATTRIBUTE, os.path.basename(texture))
            continue
        # Named after its content: images with the same file name in different
        # folders or scenes stay apart, and an edited image gets a new name
        with open(source, 'rb') as f:
            digest = files.short_hash(f.read())
        copy = '%s_%s' % (digest, os.path.basename(texture))
        if not os.path.exists(os.path.join(texture_folder, copy)):
            shutil.copy2(source, os.path.join(texture_folder, copy))
        element.setValueString('textures/' + copy)


def restore_blend_modes(doc, material):
    """Puts back the blend modes of colour Mix nodes. Blender exports every colour
    Mix node as a plain mix. For the blend modes in mx_report.BLEND_MODES, the
    mix's foreground becomes the blend of its two colours, which is how Blender
    computes them: mix(A, blend(A, B), factor). With Clamp Result, Blender exports
    a clamp (named after the node) around the mix, which stays. Only the
    material's own tree is handled: Mix nodes inside node groups keep the warning
    (mx_report.report_unexported())."""
    if material is None or material.node_tree is None:
        return
    from pxr import Tf
    for node in material.node_tree.nodes:
        if node.type != 'MIX' or node.data_type != 'RGBA' or node.blend_type not in mx_report.BLEND_MODES:
            continue
        suffix = '_bnode__%s_Result_Color' % Tf.MakeValidIdentifier(node.name)
        mix = next((n for n in doc.getNodes() if n.getName().endswith(suffix)), None)
        if mix is not None and mix.getCategory() == 'clamp':
            mix = mix.getInput('in').getConnectedNode()  # Clamp Result: Blender clamps the mix itself
        if mix is None:
            # Not in the export: Blender dropped what it feeds (for example a Color
            # Ramp, reported by mx_report.report_unexported()), so there is nothing to restore
            continue
        if mix.getCategory() != 'mix':
            raise RuntimeError('Viewport renderer: material "%s": the Mix node "%s" is exported as %s'
                               % (mx_report.display_name(material), node.name, mix.getCategory()))
        blend = doc.addNode(mx_report.BLEND_MODES[node.blend_type], mix.getName() + '_blend', 'color3')
        for source, target in (('bg', 'in1'), ('fg', 'in2')):
            inp = mix.getInput(source)
            copy = blend.addInput(target, 'color3')
            if inp.getConnectedNode() is not None:
                copy.setConnectedNode(inp.getConnectedNode())
            else:
                copy.setValueString(inp.getValueString())
        fg = mix.getInput('fg')
        fg.removeAttribute('value')
        fg.setConnectedNode(blend)


def missing_image(texture_folder: str) -> str:
    """A 1x1 magenta image (in `texture_folder`). Eevee draws an image it cannot
    load as magenta, (1, 0, 1), in every colour space."""
    path = os.path.join(texture_folder, MISSING_IMAGE)
    if not os.path.isfile(path):
        def chunk(chunk_type: bytes, data: bytes) -> bytes:
            return (struct.pack('>I', len(data)) + chunk_type + data
                    + struct.pack('>I', zlib.crc32(chunk_type + data) & 0xffffffff))
        files.write_if_changed(path, b'\x89PNG\r\n\x1a\n'
                               + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))  # 1x1, 8-bit RGBA
                               + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\xff\xff'))  # filter 0, magenta
                               + chunk(b'IEND', b''))
    return MISSING_IMAGE


def report_missing_images(material, path: str):
    """Warns, on every build, about the images a material's document draws magenta."""
    with open(path, encoding='utf-8') as f:
        missing = sorted(set(re.findall(r'%s="([^"]+)"' % MISSING_ATTRIBUTE, f.read())))
    if missing and context.warn_once('missing image', mx_report.display_name(material)):
        log.warn('Viewport renderer: material "%s": image %s could not be exported by Blender (missing or '
                 'unreadable file); it renders magenta, as in Blender'
                 % (mx_report.display_name(material), ', '.join('"%s"' % name for name in missing)))


def surface_property(prim):
    """Connection on the material's `outputs:mtlx:surface` port, if any."""
    from pxr import Usd
    for prop in prim.GetProperties():
        if not prop.GetName().startswith('outputs:mtlx:'):
            continue
        connections = list(prop.GetConnections()) if isinstance(prop, Usd.Attribute) else list(prop.GetTargets())
        if connections:
            return connections[0]
    return None


def blender_name(prim) -> str:
    """The Blender material name of a USD material prim (USD prim names are sanitised)."""
    data_name = prim.GetAttribute('userProperties:blender:data_name')
    return str(data_name.Get()) if data_name and data_name.Get() else prim.GetName()


class Extractor:
    """Walks one material's USD network (Shader prims whose info:id is a MaterialX
    nodedef) and rebuilds it as MaterialX nodes."""

    def __init__(self, stage, node_definitions: dict, name):
        import MaterialX as mx
        self.mx = mx
        self.stage = stage
        self.nodedefs = node_definitions
        self.name = name
        self.doc = mx.createDocument()
        self.nodes = {}
        self.outputs = {}
        self.textures = []  # (path in the USD export folder, document input)
        self.dropped = []

    def extract(self, material_prim):
        mx = self.mx
        surface, output = self.resolve(surface_property(material_prim))
        material = self.doc.addNode('surfacematerial', mx.createValidName(self.name), 'material')
        connection = material.addInput('surfaceshader', 'surfaceshader')
        connection.setConnectedNode(surface)
        if output is not None and surface.isMultiOutputType():
            connection.setConnectedOutput(output)
        self.doc.setVersionString('1.39')
        return self.doc

    def resolve(self, prop_path):
        """(node, output) for a USD property path such as .../node.outputs:out."""
        key = (str(prop_path.GetPrimPath()), prop_path.name)
        if key in self.outputs:
            return self.nodes[prop_path.GetPrimPath()], self.outputs[key]
        prim = self.stage.GetPrimAtPath(prop_path.GetPrimPath())
        info_id = prim.GetAttribute('info:id')
        if info_id and info_id.HasAuthoredValue():
            node = self.nodes.get(prim.GetPath()) or self.create_node(prim, str(info_id.Get()))
            return node, self.outputs.get(key)
        # A pass-through port (node graph or material output): follow it
        port = prim.GetAttribute(prop_path.name)
        if port and list(port.GetConnections()):
            return self.resolve(list(port.GetConnections())[0])
        relationship = prim.GetRelationship(prop_path.name)
        if relationship and list(relationship.GetTargets()):
            return self.resolve(list(relationship.GetTargets())[0])
        raise RuntimeError('MaterialX export of "%s": dangling port %s' % (self.name, prop_path))

    def find_nodedef(self, info_id):
        if info_id in self.nodedefs:
            return self.nodedefs[info_id]
        base = info_id.split(':')[0]
        if base in self.nodedefs:
            return self.nodedefs[base]
        match = VERSIONED_ID.match(base)
        return self.nodedefs.get(match.group(1)) if match else None

    def create_node(self, prim, info_id):
        mx = self.mx
        nodedef = self.find_nodedef(info_id)
        if nodedef is None:
            raise RuntimeError('MaterialX export of "%s": unknown nodedef %s' % (self.name, info_id))
        node = self.doc.addNode(nodedef.getNodeString(), mx.createValidName('%s_%s' % (self.name, prim.GetName())),
                                nodedef.getType())
        if not nodedef.getVersionString():
            node.setNodeDefString(nodedef.getName())
        for out in nodedef.getOutputs():
            node.addOutput(out.getName(), out.getType())
        self.nodes[prim.GetPath()] = node

        # USD names outputs as UsdShade does, MaterialX after the nodedef. A nodedef
        # with a single output takes any USD output name.
        single = nodedef.getOutputs()[0].getName() if len(nodedef.getOutputs()) == 1 else None
        for attr in prim.GetAttributes():
            if attr.GetName().startswith('outputs:'):
                usd_name = attr.GetName()[len('outputs:'):]
                out = node.getOutput(usd_name) or (node.getOutput(single) if single else None)
                if out is None:
                    self.dropped.append(('output not mapped', '%s.%s' % (node.getName(), usd_name)))
                self.outputs[(str(prim.GetPath()), attr.GetName())] = out
        for attr in prim.GetAttributes():
            if attr.GetName().startswith('inputs:'):
                self.set_input(node, nodedef, attr.GetName()[len('inputs:'):], attr)
        return node

    def set_input(self, node, nodedef, name, attr):
        mx = self.mx
        declared = nodedef.getInput(name)
        if declared is None:
            self.dropped.append(('input not in nodedef', '%s.%s' % (node.getName(), name)))
            return
        mx_type = declared.getType()
        if name == 'file' and mx_type == 'string':
            # Blender's MaterialX 1.39.4 turns the type `filename` into `string`,
            # but the data library declares `filename`
            mx_type = 'filename'
        connections = list(attr.GetConnections())
        if not connections:
            relationship = attr.GetPrim().GetRelationship(attr.GetName())
            connections = list(relationship.GetTargets()) if relationship else []
        value = None if connections else attr.Get()
        if not connections and value is None:
            return  # nothing authored: the nodedef default applies
        element = node.addInput(name, mx_type)

        if connections:
            upstream, output = self.resolve(connections[0])
            element.setConnectedNode(upstream)
            if output is not None and upstream.isMultiOutputType():
                element.setConnectedOutput(output)
            return

        if mx_type in ('float', 'integer', 'boolean'):
            element.setValue({'float': float, 'integer': int, 'boolean': bool}[mx_type](value))
        elif mx_type == 'filename':
            original = str(value).replace('\\', '/').strip('@')
            self.textures.append((original, element))  # copy_textures() copies it and sets the copy's name
            # Blender writes the image's colour space as metadata on this input
            color_space = attr.GetMetadata('colorSpace')
            if color_space:
                element.setColorSpace(str(color_space))
        elif mx_type == 'string':
            element.setValueString(str(value))
        elif mx_type in OPAQUE_TYPES:
            node.removeInput(name)
        else:
            ctor = {'vector2': mx.Vector2, 'vector3': mx.Vector3, 'vector4': mx.Vector4, 'color3': mx.Color3,
                    'color4': mx.Color4, 'matrix33': mx.Matrix33, 'matrix44': mx.Matrix44}.get(mx_type)
            if ctor is None:
                self.dropped.append(('unsupported input type', '%s.%s: %s' % (node.getName(), name, mx_type)))
                node.removeInput(name)
                return
            element.setValue(ctor(*[float(v) for v in value]))
        element.setType(mx_type)
