"""Materials as MaterialX documents, from Blender's own export (Viewport renderer).

build() runs before the scenes are exported (called by the renderer's render path
build, such as raster/renderpath.py). For every exported scene it finds the
materials in use. It exports the ones not cached yet with Blender's USD exporter,
which writes a MaterialX network, inside Blender's own process. Then it rebuilds
a standalone MaterialX document per material from the USD network (mx_extract.py):

    compiled/MaterialX/<hash>.mtlx
    compiled/Assets/viewport_textures/<content hash>_<image>   (compiled/Assets is packed whole)

A material is identified by its hash, not its name, because linked .blend files
can each have their own "Wood". The hash covers the material's node tree,
including node groups, images and their colour spaces. So unchanged materials
are never exported again, and materials with the same tree share a document.

The materials to export go into a temporary scene (export_copies()). It holds
one copy of each material's lightest user object, with the material in every
slot. This way the export's cost follows what changed, not the scene's size.
Blender's export merges materials of the same name, so materials that share a
name go into separate exports.

Nodes that Blender does not export to MaterialX, or exports as a wrong
constant, are reported once per material (mx_report.py). Their output is
whatever Blender exported.

AOV Outputs are not in Blender's export. Each AOV that the scene's view layer
declares is exported from a temporary copy of its material, whose emission is
the AOV's input (build_aovs(), mx_aov.py), into a document of its own.

document(material) returns a material's document path for the shader stage, and
aov_documents(material) returns its AOV outputs' documents.
"""
import os
import re
import shutil
import tempfile

import bpy

import arm
import arm.viewport.context as context
import arm.viewport.files as files
import arm.viewport.mx_aov as mx_aov
import arm.viewport.mx_extract as mx_extract
import arm.viewport.mx_report as mx_report
import arm.viewport.signature as signature
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    mx_aov = arm.reload_module(mx_aov)
    mx_extract = arm.reload_module(mx_extract)
    mx_report = arm.reload_module(mx_report)
    signature = arm.reload_module(signature)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

FOLDER = 'MaterialX'

DEFAULT = 'arm_viewport_default'  # temporary material, mesh, object and scene for build_default()


# --- The documents of a build ---------------------------------------------------

def document(material) -> str:
    """The material's document path, or None if it has none."""
    # armdefault, armdefaultskin and armdefaultpart are made by the exporter, after
    # build(), for objects without a material. Eevee shades those as a new material.
    if material.name.startswith('armdefault'):
        return context.current().default_document
    # Variants (_armskin, _armtile, _armskey, _armpart) are copies that the exporter
    # makes after build(). They have the same node tree, so the same hash and document.
    return context.current().documents.get(material_hash(material))


def aov_documents(material) -> list:
    """[(AOV name, 'COLOR' or 'VALUE', document path)] of the material's AOV
    outputs that its scenes declare, sorted by name."""
    if material.name.startswith('armdefault'):
        return []
    found = context.current().aov_documents.get(material_hash(material), {})
    return [(name, aov_type, path) for name, (aov_type, path) in sorted(found.items()) if os.path.exists(path)]


def scene_aovs(scene) -> list:
    """The AOVs the scene declares, as Blender renders them: [(name, 'COLOR' or
    'VALUE')] of the first view layer used for rendering."""
    layer = next((layer for layer in scene.view_layers if layer.use), scene.view_layers[0])
    return [(aov.name, aov.type) for aov in layer.aovs if aov.is_valid]


def material_hash(material) -> str:
    """The material's key: a hash of its node tree's signature, computed once per
    build. It is keyed by the material itself, because the variants the exporter
    makes during the build are new materials."""
    hashes = context.current().material_hashes
    key = (material.as_pointer(), material.name_full)
    if key not in hashes:
        text = '%s %s ' % (export_key(), bpy.app.version_string)
        if material.node_tree is not None:
            text += signature.tree_signature(material.node_tree, context.current().group_signatures)
        hashes[key] = files.short_hash(text)
    return hashes[key]


def export_key() -> str:
    """Changes with the code that exports and extracts the documents (the mx_
    modules and signature.py), so edited code gives new documents."""
    modules = (mx_extract, mx_aov, mx_report, signature)
    return files.source_key(os.path.abspath(__file__), *(os.path.abspath(module.__file__) for module in modules))


def document_path(folder: str, key: str) -> str:
    return os.path.join(folder, key + '.mtlx')


def texture_folder() -> str:
    return files.build_assets('viewport_textures')


# --- The build ------------------------------------------------------------------

def build():
    """Exports the documents of every exported scene's materials (see the module docstring)."""
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', FOLDER)
    os.makedirs(folder, exist_ok=True)
    remove_unfinished_exports(folder)
    os.makedirs(texture_folder(), exist_ok=True)

    for scene in context.exported_scenes():
        users = scene_materials(scene)
        keys = {material: material_hash(material) for material in users}
        build_materials(users, keys, folder)
        build_aovs(scene, users, keys, folder)
    build_default(folder)
    prune()


def remove_unfinished_exports(folder: str):
    """Removes the exports left behind by a Blender that stopped mid-export
    (export() removes its own)."""
    for name in os.listdir(folder):
        if name.startswith('_export') and os.path.isdir(os.path.join(folder, name)):
            shutil.rmtree(os.path.join(folder, name), ignore_errors=True)


def build_materials(users: dict, keys: dict, folder: str):
    """Exports the documents of a scene's materials that have none yet, and lists
    the scene's documents in the build context. `users` is scene_materials() and
    `keys` maps each material to its hash."""
    documents = context.current().documents
    missing = {}  # hash -> material, for materials not exported yet
    for material, key in keys.items():
        mx_report.report_unexported(material)
        if key not in documents and not os.path.exists(document_path(folder, key)):
            missing.setdefault(key, material)
    for batch in export_batches(missing, users, folder):
        export_copies(batch, folder)
    for key in set(keys.values()):
        if os.path.exists(document_path(folder, key)):
            documents[key] = document_path(folder, key)
    for material, key in keys.items():
        if key in documents:
            mx_extract.report_missing_images(material, documents[key])


def export_batches(missing: dict, users: dict, folder: str) -> list:
    """Splits the materials to export (hash -> material) into batches for
    export_copies(). Blender's export merges materials of the same name, so each
    batch holds at most one material of each name."""
    batches = []
    for key, material in missing.items():
        batch = next((b for b in batches if material.name not in b), None)
        if batch is None:
            batch = {}
            batches.append(batch)
        batch[material.name] = (material, document_path(folder, key), users[material])
    return batches


def prune():
    """Deletes the textures of edited or removed materials: the build folder is
    kept between builds."""
    files.prune(texture_folder(), used_textures())


def used_textures() -> set:
    """File names (in texture_folder()) the documents of this build use."""
    used = set()
    for path in set(context.current().documents.values()):
        with open(path, encoding='utf-8') as f:
            used.update(re.findall(r'value="textures/([^"]+)"', f.read()))
    return used


def scene_materials(scene) -> dict:
    """The materials of the scene's objects, collection instances included, each
    mapped to its lightest user object (fewest faces). That object is exported in
    the material's place (export_copies()), so the export has a mesh with the UV
    maps and attributes the material reads."""
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


def build_aovs(scene, users: dict, keys: dict, folder: str):
    """Exports the AOV outputs of the scene's materials, for the AOVs the scene
    declares. Blender's MaterialX export leaves AOV Outputs out, so each one is
    exported from a temporary copy of its material (mx_aov.aov_material()), into
    a document of its own."""
    declared = dict(scene_aovs(scene))
    if not declared:
        return
    ctx = context.current()
    documents = {}  # AOV document key -> path
    wanted = {}  # temporary material name -> (material, path, object using the original)
    for material, key in keys.items():
        # As in Eevee, Blended materials write no AOVs, even those drawn opaque
        if material.node_tree is None or material.surface_render_method == 'BLENDED':
            continue
        for name, node in mx_aov.aov_outputs(material).items():
            if name not in declared:
                continue  # Eevee writes only the AOVs of the view layer
            aov_type = ctx.aov_types.setdefault(name, declared[name])
            if aov_type != declared[name] and context.warn_once('aov type', name):
                log.warn('Viewport renderer: the AOV "%s" is a %s in one scene and a %s in another; '
                         'it is exported as a %s everywhere' % (name, aov_type.lower(), declared[name].lower(),
                                                                aov_type.lower()))
            aov_key = files.short_hash('%s %s %s' % (key, name, aov_type))
            path = document_path(folder, aov_key)
            ctx.aov_documents.setdefault(key, {})[name] = (aov_type, path)
            documents[aov_key] = path
            if os.path.exists(path):
                continue
            temp = mx_aov.aov_material(material, node, aov_type, 'arm_aov_' + aov_key)
            wanted[temp.name] = (temp, path, users[material])

    if wanted:
        try:
            export_copies(dict(wanted), folder)
        finally:
            for temp, _, _ in wanted.values():
                bpy.data.materials.remove(temp)
    # Listed with the documents, so prune() keeps them and their textures (if
    # Blender exported them)
    for aov_key, path in documents.items():
        if os.path.exists(path):
            ctx.documents[aov_key] = path


def build_default(folder: str):
    """Exports the document for objects without a material. The exporter gives
    them its armdefault materials (made after build()), and Eevee shades them as
    a new material. So Blender exports a new material from a temporary scene,
    once per Blender version."""
    digest = files.short_hash('%s %s' % (export_key(), bpy.app.version_string))
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
        mx_report.report_missing(export(scene, {material.name: (material, path)}, folder))
    finally:
        bpy.data.scenes.remove(scene)
        bpy.data.objects.remove(obj)
        bpy.data.meshes.remove(mesh)
        bpy.data.materials.remove(material)


# --- Blender's export -----------------------------------------------------------

def export_copies(wanted: dict, folder: str):
    """Exports materials from a temporary scene that holds a copy of each object,
    with its material in every slot (material_copy()). `wanted` maps a unique
    name to (material, .mtlx path, an object using it)."""
    scene = bpy.data.scenes.new(DEFAULT)
    copies = []
    try:
        for material, _, obj in wanted.values():
            copy = material_copy(obj, material)
            scene.collection.objects.link(copy)
            copies.append(copy)
        mx_report.report_missing(export(scene, {name: (material, path) for name, (material, path, _) in wanted.items()},
                                        folder))
    finally:
        bpy.data.scenes.remove(scene)
        for copy in copies:
            bpy.data.objects.remove(copy)


def material_copy(obj, material):
    """A copy of `obj` with `material` in every slot. The copy keeps the object's
    mesh, with the UV maps and attributes the material reads. Every face uses the
    material, so Blender's export includes it: Blender leaves out materials that
    no face uses."""
    copy = obj.copy()
    copy.parent = None
    for slot in copy.material_slots:
        slot.link = 'OBJECT'
        slot.material = material
    return copy


def export(scene, wanted: dict, folder: str) -> dict:
    """Exports the scene with Blender's USD exporter and writes the documents of
    the `wanted` materials (name -> (material, .mtlx path)). The names must be
    unique in the scene, because Blender's export merges materials of the same
    name. Returns the wanted materials Blender did not export (no face uses them)."""
    from pxr import Usd
    # The export gets a folder of its own, removed even when the export fails. USD
    # caches opened stages by path, so no two exports (of this build or of another
    # build of the same project) may share a file.
    export_folder = tempfile.mkdtemp(prefix='_export_', dir=folder)
    try:
        # Blender's export skips objects hidden in renders (render mode) or in the
        # viewport (viewport mode). Armory exports both, so both modes are tried.
        for mode in ('RENDER', 'VIEWPORT'):
            if not wanted:
                break
            usd_path = os.path.join(export_folder, 'scene_%s.usda' % mode.lower())
            with bpy.context.temp_override(scene=scene):
                bpy.ops.wm.usd_export(filepath=usd_path, export_materials=True, generate_materialx_network=True,
                                      relative_paths=True, export_lights=False, export_cameras=False,
                                      evaluation_mode=mode)
            mx_extract.extract(Usd.Stage.Open(usd_path), mx_extract.nodedefs(), wanted, export_folder,
                               texture_folder())
    finally:
        shutil.rmtree(export_folder, ignore_errors=True)
    return wanted
