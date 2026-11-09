"""Materials as MaterialX documents, from Blender's own export (Viewport renderer).

build() runs before the scenes are exported (renderpath.build()). For every
exported scene it finds the materials in use and exports the ones not cached
yet with Blender's USD exporter and its MaterialX network (in-process), then
rebuilds a standalone MaterialX document per material from the USD network:

    compiled/MaterialX/<hash>.mtlx
    compiled/Assets/viewport_textures/<content hash>_<image>   (compiled/Assets is packed whole)

A material is its hash, not its name: linked .blend files can each have their
own "Wood". The hash covers the material's node tree (node groups, images and
their colour spaces included), so unchanged materials are never exported again,
and materials with the same tree share a document. The materials to export go
into a temporary scene, one copy of each one's lightest user object with the
material in every slot (export_copies()): the export's cost follows what
changed, not the scene's size (one material edited in a level of 1.5 M faces
took 15 s with the whole scene). Blender's export merges materials of the same
name, so materials sharing a name go into separate exports.
Nodes that Blender does not export to MaterialX, or exports as a wrong constant,
are reported once per material; their output is whatever Blender exported.

AOV Outputs are not in Blender's export: each one the scene's view layer
declares is exported as a temporary copy of its material whose emission is the
AOV's input (build_aovs()), into a document of its own.

document(material) returns a material's document path for the shader stage,
aov_documents(material) its AOV outputs' documents.
"""
import hashlib
import os
import re
import shutil
import struct
import tempfile
import zlib

import bpy

import arm
import arm.viewport.context as context
import arm.viewport.files as files
import arm.viewport.signature as signature
import arm.linked_utils as linked_utils
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    signature = arm.reload_module(signature)
    linked_utils = arm.reload_module(linked_utils)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

VERSION = '4'  # bump when the extraction changes
FOLDER = 'MaterialX'

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

DEFAULT = 'arm_viewport_default'  # temporary material, mesh, object and scene for build_default()
# An image Blender could not export is drawn with MISSING_IMAGE (missing_image()); its
# document keeps the image's name in this attribute (report_missing_images())
MISSING_IMAGE = 'viewport_missing_image.png'
MISSING_ATTRIBUTE = 'arm_missing'


def document(material) -> str:
    # armdefault, armdefaultskin, armdefaultpart: made by the exporter for objects
    # without a material, after build(); Eevee shades those as a new material
    if material.name.startswith('armdefault'):
        return context.current().default_document
    # Variants (_armskin, _armtile, _armskey, _armpart) are copies the exporter
    # makes after build(): same node tree, hence same hash and same document
    return context.current().documents.get(material_hash(material))


def build():
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', FOLDER)
    os.makedirs(folder, exist_ok=True)
    # Exports left behind by a Blender that stopped mid-export (export() removes its own)
    for name in os.listdir(folder):
        if name.startswith('_export') and os.path.isdir(os.path.join(folder, name)):
            shutil.rmtree(os.path.join(folder, name), ignore_errors=True)
    os.makedirs(texture_folder(), exist_ok=True)
    documents = context.current().documents

    for scene in context.exported_scenes():
        users = scene_materials(scene)
        keys = {material: material_hash(material) for material in users}

        missing = {}  # hash -> material, not exported yet
        for material, key in keys.items():
            report_unexported(material)
            if key not in documents and not os.path.exists(document_path(folder, key)):
                missing.setdefault(key, material)
        # Blender's export merges materials of the same name: one export per clash
        batches = []
        for key, material in missing.items():
            batch = next((b for b in batches if material.name not in b), None)
            if batch is None:
                batch = {}
                batches.append(batch)
            batch[material.name] = (material, document_path(folder, key), users[material])
        for batch in batches:
            export_copies(batch, folder)
        for key in set(keys.values()):
            if os.path.exists(document_path(folder, key)):
                documents[key] = document_path(folder, key)
        for material, key in keys.items():
            if key in documents:
                report_missing_images(material, documents[key])
        build_aovs(scene, users, keys, folder)

    build_default(folder)
    # The build folder is kept between builds: documents and textures of edited
    # or removed materials go
    documents = set(context.current().documents.values()) | {context.current().default_document}
    files.prune(folder, {os.path.basename(path) for path in documents}, lambda name: name.endswith('.mtlx'))
    files.prune(texture_folder(), used_textures())


def document_path(folder: str, key: str) -> str:
    return os.path.join(folder, key + '.mtlx')


# --- AOV outputs ----------------------------------------------------------------

def scene_aovs(scene) -> list:
    """The AOVs the scene declares, as Blender renders them: [(name, 'COLOR' or
    'VALUE')] of its first view layer used for rendering."""
    layer = next((layer for layer in scene.view_layers if layer.use), scene.view_layers[0])
    return [(aov.name, aov.type) for aov in layer.aovs if aov.is_valid]


def aov_documents(material) -> list:
    """[(AOV name, 'COLOR' or 'VALUE', document path)] of the material's AOV
    outputs that its scenes declare, by name."""
    if material.name.startswith('armdefault'):
        return []
    found = context.current().aov_documents.get(material_hash(material), {})
    return [(name, kind, path) for name, (kind, path) in sorted(found.items()) if os.path.exists(path)]


def aov_outputs(material) -> dict:
    """The material's AOV Output nodes by AOV name (its own tree)."""
    outputs = {}
    for node in sorted(material.node_tree.nodes, key=lambda n: n.name):
        if node.type != 'OUTPUT_AOV' or node.mute or not node.aov_name:
            continue
        if node.aov_name in outputs:
            if context.warn_once('aov twice', '%s/%s' % (display_name(material), node.aov_name)):
                log.warn('Viewport renderer: material "%s" has several AOV Outputs named "%s"; only "%s" is used'
                         % (display_name(material), node.aov_name, outputs[node.aov_name].name))
            continue
        outputs[node.aov_name] = node

    def in_groups(tree, seen):
        for node in tree.nodes:
            if node.type == 'GROUP' and node.node_tree is not None and node.node_tree not in seen:
                seen.add(node.node_tree)
                if any(n.type == 'OUTPUT_AOV' for n in node.node_tree.nodes) or in_groups(node.node_tree, seen):
                    return True
        return False
    if in_groups(material.node_tree, set()) and context.warn_once('aov group', display_name(material)):
        log.warn('Viewport renderer: material "%s": AOV Outputs inside node groups are not supported; '
                 'put them in the material itself' % display_name(material))
    return outputs


def build_aovs(scene, users: dict, keys: dict, folder: str):
    """Exports the AOV outputs of the scene's materials that the scene declares.
    Blender's MaterialX export leaves AOV Outputs out, so each one is exported as
    a temporary copy of its material (aov_material()), with a document of its own."""
    declared = dict(scene_aovs(scene))
    if not declared:
        return
    ctx = context.current()
    documents = {}  # AOV document key -> path
    wanted = {}  # temporary material name -> (material, path, object using the original)
    for material, key in keys.items():
        # Measured: Blended materials write no AOVs, even the ones drawn opaque
        if material.node_tree is None or material.surface_render_method == 'BLENDED':
            continue
        for name, node in aov_outputs(material).items():
            if name not in declared:
                continue  # Eevee writes only the AOVs of the view layer
            kind = ctx.aov_types.setdefault(name, declared[name])
            if kind != declared[name] and context.warn_once('aov type', name):
                log.warn('Viewport renderer: the AOV "%s" is a %s in one scene and a %s in another; '
                         'it is exported as a %s everywhere' % (name, kind.lower(), declared[name].lower(), kind.lower()))
            aov_key = hashlib.sha1(('%s %s %s' % (key, name, kind)).encode()).hexdigest()[:12]
            path = document_path(folder, aov_key)
            ctx.aov_documents.setdefault(key, {})[name] = (kind, path)
            documents[aov_key] = path
            if os.path.exists(path):
                continue
            temp = aov_material(material, node, kind, 'arm_aov_' + aov_key)
            wanted[temp.name] = (temp, path, users[material])

    if wanted:
        try:
            export_copies(dict(wanted), folder)
        finally:
            for temp, _, _ in wanted.values():
                bpy.data.materials.remove(temp)
    # Kept by the pruning in build(), with their textures, if Blender exported them
    for aov_key, path in documents.items():
        if os.path.exists(path):
            ctx.documents[aov_key] = path


def aov_material(material, node, kind: str, name: str):
    """A copy of the material whose emission is the AOV Output's input (Color or
    Value, by the AOV's type), with nothing else but the material's alpha: its
    pass writes the emission as the AOV (materials.py), and leaves out the pixels
    the material leaves out (Dithered alpha), as Eevee does."""
    copy = material.copy()
    copy.name = name
    tree = copy.node_tree
    source = tree.nodes[node.name].inputs['Color' if kind == 'COLOR' else 'Value']
    output = tree.get_output_node('EEVEE')
    if output is None:
        output = tree.nodes.new('ShaderNodeOutputMaterial')
    surface = output.inputs['Surface'].links[0].from_node if output.inputs['Surface'].is_linked else None
    if surface is not None and surface.type == 'BSDF_PRINCIPLED':
        for link in list(tree.links):
            if link.to_node == surface and link.to_socket.identifier != 'Alpha':
                tree.links.remove(link)
        surface.inputs['Emission Strength'].default_value = 1.0
        target = surface.inputs['Emission Color']
    else:
        emission = tree.nodes.new('ShaderNodeEmission')
        emission.inputs['Strength'].default_value = 1.0
        tree.links.new(emission.outputs[0], output.inputs['Surface'])
        target = emission.inputs['Color']
    if source.is_linked:
        tree.links.new(source.links[0].from_socket, target)
    else:
        value = source.default_value
        target.default_value = tuple(value) if kind == 'COLOR' else (value, value, value, 1.0)
    return copy


def build_default(folder: str):
    """Objects without a material get the exporter's armdefault materials (made
    after build()); Eevee shades them as a new material. Blender exports one, on
    a temporary scene, once per Blender version."""
    digest = hashlib.sha1(('%s %s' % (VERSION, bpy.app.version_string)).encode()).hexdigest()[:12]
    path = os.path.join(folder, 'default_%s.mtlx' % digest)
    context.current().default_document = path
    if os.path.exists(path):
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
        report_missing(export(scene, {material.name: (material, path)}, folder))
    finally:
        bpy.data.scenes.remove(scene)
        bpy.data.objects.remove(obj)
        bpy.data.meshes.remove(mesh)
        bpy.data.materials.remove(material)


def export_copies(wanted: dict, folder: str):
    """Exports materials (name -> (material, .mtlx path, an object using it); names
    unique) from a temporary scene holding a copy of each object with its material
    in every slot (material_copy())."""
    scene = bpy.data.scenes.new(DEFAULT)
    copies = []
    try:
        for material, _, obj in wanted.values():
            copy = material_copy(obj, material)
            scene.collection.objects.link(copy)
            copies.append(copy)
        report_missing(export(scene, {name: (material, path) for name, (material, path, _) in wanted.items()}, folder))
    finally:
        bpy.data.scenes.remove(scene)
        for copy in copies:
            bpy.data.objects.remove(copy)


def material_copy(obj, material):
    """A copy of `obj` with `material` in every slot. The copy keeps the object's
    mesh, with its UV maps and attributes (what the material reads), and every
    face uses the material, so Blender's export includes it: Blender leaves out
    materials no face uses."""
    copy = obj.copy()
    copy.parent = None
    for slot in copy.material_slots:
        slot.link = 'OBJECT'
        slot.material = material
    return copy


def report_missing(wanted: dict):
    """Warns about the materials export() could not write (what it returns)."""
    for material, _ in wanted.values():
        log.warn('Viewport renderer: material "%s" was not exported to MaterialX by Blender' % display_name(material))


def export(scene, wanted: dict, folder: str) -> dict:
    """Exports the scene with Blender's USD exporter and writes the documents of
    the `wanted` materials (name -> (material, .mtlx path)); names must be
    unique in the scene, Blender's export merges materials of the same name.
    Returns the wanted materials Blender did not export (no face uses them)."""
    from pxr import Usd
    # A folder of its own, removed even when the export fails: USD caches opened
    # stages by path, so no two exports (of this build or of another build of the
    # same project) may share a file
    export_folder = tempfile.mkdtemp(prefix='_export_', dir=folder)
    try:
        # Blender's export skips objects hidden in renders (render mode) or in the
        # viewport (viewport mode); Armory exports both, so try both
        for mode in ('RENDER', 'VIEWPORT'):
            if not wanted:
                break
            usd_path = os.path.join(export_folder, 'scene_%s.usda' % mode.lower())
            with bpy.context.temp_override(scene=scene):
                bpy.ops.wm.usd_export(filepath=usd_path, export_materials=True, generate_materialx_network=True,
                                      relative_paths=True, export_lights=False, export_cameras=False,
                                      evaluation_mode=mode)
            extract(Usd.Stage.Open(usd_path), nodedefs(), wanted, export_folder, folder)
    finally:
        shutil.rmtree(export_folder, ignore_errors=True)
    return wanted


def nodedefs() -> dict:
    """MaterialX's node definitions by name, loaded once."""
    ctx = context.current()
    if ctx.nodedefs is None:
        import MaterialX as mx
        library = mx.createDocument()
        mx.loadLibraries(mx.getDefaultDataLibraryFolders(), mx.getDefaultDataSearchPath(), library)
        ctx.nodedefs = {nd.getName(): nd for nd in library.getNodeDefs()}
    return ctx.nodedefs


def extract(stage, nodedefs, wanted: dict, usd_folder: str, folder: str):
    """Writes the documents of the `wanted` materials found in the stage (removing them from `wanted`)."""
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
        extractor = Extractor(stage, nodedefs, display_name(material))
        doc = extractor.extract(prim)
        for kind, detail in extractor.dropped:
            log.warn('Viewport renderer: material "%s": %s %s' % (display_name(material), kind, detail))
        restore_blend_modes(doc, material)
        for texture, element in extractor.textures:
            source = os.path.join(usd_folder, texture)
            if not os.path.isfile(source):
                # Blender found nothing to export (a missing or unreadable file): Eevee
                # draws such an image magenta. Reported on every build (report_missing_images())
                element.setValueString('textures/' + missing_image())
                element.setAttribute(MISSING_ATTRIBUTE, os.path.basename(texture))
                continue
            # Named after its content: images with the same file name in different
            # folders or scenes stay apart, and an edited image gets a new name
            with open(source, 'rb') as f:
                digest = hashlib.sha1(f.read()).hexdigest()[:12]
            copy = '%s_%s' % (digest, os.path.basename(texture))
            if not os.path.exists(os.path.join(texture_folder(), copy)):
                shutil.copy2(source, os.path.join(texture_folder(), copy))
            element.setValueString('textures/' + copy)
        mx.writeToXmlFile(doc, path)


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
        if mix is None:
            # Not in the export: what it feeds was dropped by Blender (e.g. a Color
            # Ramp, reported by report_unexported), so there is nothing to restore
            continue
        if mix.getCategory() != 'mix':
            raise RuntimeError('Viewport renderer: material "%s": the Mix node "%s" is exported as %s'
                               % (display_name(material), node.name, mix.getCategory()))
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
    return files.build_assets('viewport_textures')


def missing_image() -> str:
    """A 1x1 magenta image (in texture_folder()): what Eevee draws for an image it
    cannot load (measured: (1, 0, 1), the same in every colour space)."""
    path = os.path.join(texture_folder(), MISSING_IMAGE)
    if not os.path.isfile(path):
        def chunk(kind: bytes, data: bytes) -> bytes:
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        files.write_if_changed(path, b'\x89PNG\r\n\x1a\n'
                               + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))  # 1x1, 8-bit RGBA
                               + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\xff\xff'))  # filter 0, magenta
                               + chunk(b'IEND', b''))
    return MISSING_IMAGE


def report_missing_images(material, path: str):
    """Warns, on every build, about the images a material's document draws magenta."""
    with open(path, encoding='utf-8') as f:
        missing = sorted(set(re.findall(r'%s="([^"]+)"' % MISSING_ATTRIBUTE, f.read())))
    if missing and context.warn_once('missing image', display_name(material)):
        log.warn('Viewport renderer: material "%s": image %s could not be exported by Blender (missing or '
                 'unreadable file); it renders magenta, as in Blender'
                 % (display_name(material), ', '.join('"%s"' % name for name in missing)))


def used_textures() -> set:
    """File names (in texture_folder()) the documents of this build use."""
    used = set()
    for path in set(context.current().documents.values()):
        with open(path, encoding='utf-8') as f:
            used.update(re.findall(r'value="textures/([^"]+)"', f.read()))
    return used


def scene_materials(scene) -> dict:
    """Materials of the scene's objects, collection instances included -> its
    lightest user (fewest faces): exported in its place (export_copies()), it keeps
    that object's mesh with the UV maps and attributes the material reads."""
    found = {}

    def weight(obj) -> int:
        mesh = obj.data if obj.type == 'MESH' else None
        return len(mesh.polygons) if mesh is not None else 1 << 30  # other types: only when no mesh uses it

    def visit(objects):
        for obj in objects:
            for slot in getattr(obj, 'material_slots', []):
                material = slot.material
                if material is not None and (material not in found or weight(obj) < weight(found[material])):
                    found[material] = obj
            if obj.instance_type == 'COLLECTION' and obj.instance_collection is not None:
                visit(obj.instance_collection.all_objects)
    visit(scene.objects)
    return found


def display_name(material) -> str:
    """The material's name in messages: linked materials carry their library's suffix."""
    return linked_utils.asset_name(material)


def material_hash(material) -> str:
    """The material's key: its node tree's signature, computed once per build (the
    exporter's variants of a material, made during the build, are new materials)."""
    hashes = context.current().material_hashes
    key = (material.as_pointer(), material.name_full)
    if key not in hashes:
        digest = hashlib.sha1(('%s %s ' % (VERSION, bpy.app.version_string)).encode())
        if material.node_tree is not None:
            digest.update(signature.tree_signature(material.node_tree, context.current().group_signatures).encode())
        hashes[key] = digest.hexdigest()[:12]
    return hashes[key]


def report_unexported(material):
    if material.node_tree is None or not context.warn_once('export', display_name(material)):
        return
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
                log.warn('Viewport renderer: material "%s": the Mix node ("%s") is exported by Blender as a plain '
                         'Mix, its %s blend mode is lost' % (display_name(material), node.name,
                                                             node.bl_rna.properties['blend_type'].enum_items[node.blend_type].name))
            elif (node.type == 'NORMAL_MAP' and node.space == 'TANGENT' and node.inputs['Color'].is_linked
                  and (node.inputs['Strength'].is_linked or node.inputs['Strength'].default_value > 0.0)):
                # Meshes are exported without tangents: the vertex stage builds one
                # from the normal, which is not the UV tangent
                log.warn('Viewport renderer: material "%s": the Normal Map node ("%s") needs mesh tangents, '
                         'which are not exported; it renders with the wrong orientation'
                         % (display_name(material), node.name))
    visit(material.node_tree)
    for kind in sorted(found):
        if kind in NOT_EXPORTED:
            log.warn('Viewport renderer: material "%s": the %s node ("%s") is not exported to MaterialX by Blender; '
                     'its output is replaced by a constant' % (display_name(material), NOT_EXPORTED[kind], found[kind]))
        else:
            log.warn('Viewport renderer: material "%s": the %s node ("%s") is exported by Blender as a constant '
                     'that does not match Eevee' % (display_name(material), WRONG_CONSTANT[kind], found[kind]))


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
            self.textures.append((original, element))  # extract() copies it and sets the copy's name
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
