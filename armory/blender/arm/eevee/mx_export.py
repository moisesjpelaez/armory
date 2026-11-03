"""Materials as MaterialX documents, from Blender's own export (Eevee renderer).

build() runs before the scenes are exported (renderpath.build()). For every
exported scene it finds the materials in use and, when one is not cached yet,
exports the scene with Blender's USD exporter and its MaterialX network
(in-process, no temporary scenes or objects), then rebuilds a standalone
MaterialX document per material from the USD network:

    compiled/MaterialX/<material>_<hash>.mtlx
    compiled/Assets/eevee_textures/<image>   (compiled/Assets is packed whole)

The hash covers the material's node tree (node groups, images and their colour
spaces included), so unchanged materials are never exported again. Nodes that
Blender does not export to MaterialX, or exports as a wrong constant, are
reported once per material; their output is whatever Blender exported.

document(material) returns a material's document path for the shader stage.
"""
import hashlib
import json
import os
import re
import shutil

import bpy

import arm
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

VERSION = '2'  # bump when the extraction changes
FOLDER = 'MaterialX'
TEXTURES = os.path.join('Assets', 'eevee_textures')  # under compiled/

# Blender nodes its MaterialX export loses or turns into a wrong constant
# (measured, materialx-recon/phase0/coverage)
NOT_EXPORTED = {
    'VERTEX_COLOR': 'Color Attribute', 'ATTRIBUTE': 'Attribute', 'OBJECT_INFO': 'Object Info',
    'VALTORGB': 'Color Ramp', 'TEX_VORONOI': 'Voronoi Texture', 'TEX_BRICK': 'Brick Texture',
    'TEX_MAGIC': 'Magic Texture', 'MIX_RGB': 'Mix (Legacy)', 'PARTICLE_INFO': 'Particle Info',
}
WRONG_CONSTANT = {'FRESNEL': 'Fresnel', 'LAYER_WEIGHT': 'Layer Weight', 'BLACKBODY': 'Blackbody'}
# Mix node colour blend modes Blender exports as a plain mix -> MaterialX node
# that restore_blend_modes() puts back (added as projects use them)
BLEND_MODES = {'MULTIPLY': 'multiply'}

_documents = {}  # material name -> .mtlx path, filled by build()
_reported = set()  # materials already warned about this session
_default = None  # Blender's default material document, set by build()
_nodedefs = None  # MaterialX node definitions by name, loaded on first export

DEFAULT = 'arm_eevee_default'  # temporary material, mesh, object and scene for build_default()


def default_document() -> str:
    """Blender's default material document (build_default())."""
    return _default


def document(material) -> str:
    # armdefault, armdefaultskin, armdefaultpart: made by the exporter for objects
    # without a material, after build(); Eevee shades those as a new material
    if material.name.startswith('armdefault'):
        return _default
    path = _documents.get(material.name)
    if path is None:
        # Variants (_armskin, _armtile, _armskey, _armpart) are copies the exporter
        # makes after build(): same node tree, hence same hash and same export
        suffix = '_%s.mtlx' % material_hash(material)
        path = next((p for p in _documents.values() if p.endswith(suffix)), None)
    return path


def build():
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', FOLDER)
    os.makedirs(folder, exist_ok=True)
    os.makedirs(texture_folder(), exist_ok=True)
    _documents.clear()

    for scene in bpy.data.scenes:
        if not scene.arm_export:
            continue
        wanted = {}
        for material in scene_materials(scene):
            path = os.path.join(folder, '%s_%s.mtlx' % (arm.utils.safesrc(material.name), material_hash(material)))
            if os.path.exists(path):
                _documents[material.name] = path
            else:
                wanted[material.name] = path
            report_unexported(material)
        if wanted:
            export(scene, wanted, folder)

    build_default(folder)


def build_default(folder: str):
    """Objects without a material get the exporter's armdefault materials (made
    after build()); Eevee shades them as a new material. Blender exports one, on
    a temporary scene, once per Blender version."""
    global _default
    digest = hashlib.sha1(('%s %s' % (VERSION, bpy.app.version_string)).encode()).hexdigest()[:12]
    _default = os.path.join(folder, 'default_%s.mtlx' % digest)
    if os.path.exists(_default):
        return
    material = bpy.data.materials.new(DEFAULT)
    material.use_nodes = True
    mesh = bpy.data.meshes.new(DEFAULT)
    mesh.from_pydata([(0, 0, 0), (1, 0, 0), (0, 1, 0)], [], [(0, 1, 2)])
    mesh.materials.append(material)
    obj = bpy.data.objects.new(DEFAULT, mesh)
    scene = bpy.data.scenes.new(DEFAULT)
    scene.collection.objects.link(obj)
    try:
        export(scene, {material.name: _default}, folder)
    finally:
        bpy.data.scenes.remove(scene)
        bpy.data.objects.remove(obj)
        bpy.data.meshes.remove(mesh)
        bpy.data.materials.remove(material)


def export(scene, wanted: dict, folder: str):
    """Exports the scene with Blender's USD exporter and writes the documents of
    the `wanted` materials (name -> .mtlx path)."""
    from pxr import Usd
    export_folder = os.path.join(folder, '_export')
    os.makedirs(export_folder, exist_ok=True)
    # Blender's export skips objects hidden in renders (render mode) or in the
    # viewport (viewport mode); Armory exports both, so try both
    for mode in ('RENDER', 'VIEWPORT'):
        if not wanted:
            break
        # One file per export: USD caches opened stages by path
        usd_path = os.path.join(export_folder, 'scene_%s.usda' % mode.lower())
        with bpy.context.temp_override(scene=scene):
            bpy.ops.wm.usd_export(filepath=usd_path, export_materials=True, generate_materialx_network=True,
                                  relative_paths=True, export_lights=False, export_cameras=False,
                                  evaluation_mode=mode)
        extract(Usd.Stage.Open(usd_path), nodedefs(), wanted, export_folder, folder)
    for name in wanted:
        log.warn('Eevee renderer: material "%s" was not exported to MaterialX by Blender' % name)
    shutil.rmtree(export_folder, ignore_errors=True)


def nodedefs() -> dict:
    """MaterialX's node definitions by name, loaded once."""
    global _nodedefs
    if _nodedefs is None:
        import MaterialX as mx
        library = mx.createDocument()
        mx.loadLibraries(mx.getDefaultDataLibraryFolders(), mx.getDefaultDataSearchPath(), library)
        _nodedefs = {nd.getName(): nd for nd in library.getNodeDefs()}
    return _nodedefs


def extract(stage, nodedefs, wanted: dict, usd_folder: str, folder: str):
    """Writes the documents of the `wanted` materials found in the stage (removing them from `wanted`)."""
    import MaterialX as mx
    for prim in stage.Traverse():
        if surface_property(prim) is None:
            continue
        name = blender_name(prim)
        if name not in wanted:
            continue
        extractor = Extractor(stage, nodedefs, name)
        doc = extractor.extract(prim)
        for kind, detail in extractor.dropped:
            log.warn('Eevee renderer: material "%s": %s %s' % (name, kind, detail))
        restore_blend_modes(doc, bpy.data.materials.get(name))
        for texture in extractor.textures:
            source = os.path.join(usd_folder, texture)
            if os.path.isfile(source):
                shutil.copy2(source, os.path.join(texture_folder(), os.path.basename(texture)))
            else:
                log.warn('Eevee renderer: material "%s": texture %s was not exported' % (name, texture))
        mx.writeToXmlFile(doc, wanted[name])
        _documents[name] = wanted.pop(name)


def restore_blend_modes(doc, material):
    """Blender exports every colour Mix node as a plain mix (measured). For the
    blend modes in BLEND_MODES, the mix's foreground becomes the blend of its two
    colours, which is how Blender computes them: mix(A, blend(A, B), factor).
    With Clamp Result, Blender exports a clamp (named after the node) around the
    mix, which stays. Only the material's own tree: Mix nodes inside node groups
    keep the warning (report_unexported)."""
    if material is None or material.node_tree is None:
        return
    from pxr import Tf
    for node in material.node_tree.nodes:
        if node.type != 'MIX' or node.data_type != 'RGBA' or node.blend_type not in BLEND_MODES:
            continue
        suffix = '_bnode__%s_Result_Color' % Tf.MakeValidIdentifier(node.name)
        mix = next((n for n in doc.getNodes() if n.getName().endswith(suffix)), None)
        if mix is not None and mix.getCategory() == 'clamp':
            mix = mix.getInput('in').getConnectedNode()  # Clamp Result: Blender clamps the mix itself
        if mix is None or mix.getCategory() != 'mix':
            raise RuntimeError('Eevee renderer: material "%s": the exported Mix node "%s" was not found'
                               % (material.name, node.name))
        blend = doc.addNode(BLEND_MODES[node.blend_type], mix.getName() + '_blend', 'color3')
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


def texture_folder() -> str:
    return os.path.join(arm.utils.get_fp_build(), 'compiled', TEXTURES)


def scene_materials(scene) -> list:
    """Materials of the scene's objects, collection instances included."""
    found = {}

    def visit(objects):
        for obj in objects:
            for slot in getattr(obj, 'material_slots', []):
                if slot.material is not None:
                    found[slot.material.name] = slot.material
            if obj.instance_type == 'COLLECTION' and obj.instance_collection is not None:
                visit(obj.instance_collection.all_objects)
    visit(scene.objects)
    return list(found.values())


def material_hash(material) -> str:
    digest = hashlib.sha1(('%s %s ' % (VERSION, bpy.app.version_string)).encode())
    if material.node_tree is not None:
        digest.update(tree_signature(material.node_tree, set()).encode())
    return digest.hexdigest()[:12]


def tree_signature(tree, seen: set) -> str:
    """Everything in a node tree that can change Blender's MaterialX export."""
    parts = []
    for node in sorted(tree.nodes, key=lambda n: n.name):
        parts.append('N%s|%s' % (node.name, node.bl_idname))
        for prop in node.bl_rna.properties:
            if prop.identifier in ('location', 'location_absolute', 'width', 'height', 'select', 'label', 'name',
                                   'dimensions', 'show_options', 'show_preview', 'hide', 'mute', 'color',
                                   'use_custom_color', 'show_texture', 'warning_propagation'):
                continue
            if prop.type in ('STRING', 'ENUM', 'BOOLEAN', 'INT', 'FLOAT'):
                parts.append('%s=%r' % (prop.identifier, getattr(node, prop.identifier)))
        image = getattr(node, 'image', None)
        if image is not None:
            parts.append('IMG%s|%s|%s' % (image.filepath, image.colorspace_settings.name, image.source))
        if node.type == 'GROUP' and node.node_tree is not None and node.node_tree.name not in seen:
            seen.add(node.node_tree.name)
            parts.append('G{%s}' % tree_signature(node.node_tree, seen))
        for socket in node.inputs:
            if not socket.is_linked and hasattr(socket, 'default_value'):
                value = socket.default_value
                parts.append('I%s=%r' % (socket.identifier, tuple(value) if hasattr(value, '__len__') else value))
    for link in tree.links:
        parts.append('L%s.%s>%s.%s' % (link.from_node.name, link.from_socket.identifier,
                                         link.to_node.name, link.to_socket.identifier))
    return ';'.join(parts)


def report_unexported(material):
    if material.name in _reported or material.node_tree is None:
        return
    _reported.add(material.name)
    found = {}

    def visit(tree):
        for node in tree.nodes:
            if node.type == 'GROUP' and node.node_tree is not None:
                visit(node.node_tree)
            elif node.type in NOT_EXPORTED or node.type in WRONG_CONSTANT:
                found[node.type] = node.name
            elif (node.type == 'MIX' and node.data_type == 'RGBA' and node.blend_type != 'MIX'
                  and (tree is not material.node_tree or node.blend_type not in BLEND_MODES)):
                # Measured: every colour blend mode is exported as a plain mix;
                # restore_blend_modes() restores the ones in BLEND_MODES
                log.warn('Eevee renderer: material "%s": the Mix node ("%s") is exported by Blender as a plain '
                         'Mix, its %s blend mode is lost' % (material.name, node.name,
                                                             node.bl_rna.properties['blend_type'].enum_items[node.blend_type].name))
    visit(material.node_tree)
    for kind in sorted(found):
        if kind in NOT_EXPORTED:
            log.warn('Eevee renderer: material "%s": the %s node ("%s") is not exported to MaterialX by Blender; '
                     'its output is replaced by a constant' % (material.name, NOT_EXPORTED[kind], found[kind]))
        else:
            log.warn('Eevee renderer: material "%s": the %s node ("%s") is exported by Blender as a constant '
                     'that does not match Eevee' % (material.name, WRONG_CONSTANT[kind], found[kind]))


# --- USD MaterialX network -> standalone document -------------------------------

VERSIONED_ID = re.compile(r'^(.*)_(\d+)_(\d+)$')
OPAQUE_TYPES = {'BSDF', 'EDF', 'VDF', 'surfaceshader', 'displacementshader', 'volumeshader',
                'lightshader', 'material'}


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
    data_name = prim.GetAttribute('userProperties:blender:data_name')
    return str(data_name.Get()) if data_name and data_name.Get() else prim.GetName()


class Extractor:
    """Walks one material's USD network (Shader prims whose info:id is a MaterialX
    nodedef) and rebuilds it as MaterialX nodes."""

    def __init__(self, stage, nodedefs, name):
        import MaterialX as mx
        self.mx = mx
        self.stage = stage
        self.nodedefs = nodedefs
        self.name = name
        self.doc = mx.createDocument()
        self.nodes = {}
        self.outputs = {}
        self.textures = []
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

        # USD names outputs after UsdShade usage, MaterialX after the nodedef
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
        kind = declared.getType()
        if name == 'file' and kind == 'string':
            # Blender's MaterialX 1.39.4 canonicalises `filename` to `string`;
            # the data library declares `filename`
            kind = 'filename'
        connections = list(attr.GetConnections())
        if not connections:
            relationship = attr.GetPrim().GetRelationship(attr.GetName())
            connections = list(relationship.GetTargets()) if relationship else []
        value = None if connections else attr.Get()
        if not connections and value is None:
            return  # nothing authored: the nodedef default applies
        element = node.addInput(name, kind)

        if connections:
            upstream, output = self.resolve(connections[0])
            element.setConnectedNode(upstream)
            if output is not None and upstream.isMultiOutputType():
                element.setConnectedOutput(output)
            return

        if kind in ('float', 'integer', 'boolean'):
            element.setValue({'float': float, 'integer': int, 'boolean': bool}[kind](value))
        elif kind == 'filename':
            original = str(value).replace('\\', '/').strip('@')
            self.textures.append(original)
            element.setValueString('textures/' + os.path.basename(original))
            # Blender writes the image's colour space as metadata on this input
            color_space = attr.GetMetadata('colorSpace')
            if color_space:
                element.setColorSpace(str(color_space))
        elif kind == 'string':
            element.setValueString(str(value))
        elif kind in OPAQUE_TYPES:
            node.removeInput(name)
        else:
            ctor = {'vector2': mx.Vector2, 'vector3': mx.Vector3, 'vector4': mx.Vector4, 'color3': mx.Color3,
                    'color4': mx.Color4, 'matrix33': mx.Matrix33, 'matrix44': mx.Matrix44}.get(kind)
            if ctor is None:
                self.dropped.append(('unsupported input type', '%s.%s: %s' % (node.getName(), name, kind)))
                node.removeInput(name)
                return
            element.setValue(ctor(*[float(v) for v in value]))
        element.setType(kind)
