"""Render path setup for the Viewport renderer (called from make_renderpath.build())."""
import json
import os

import arm
import arm.assets as assets
import arm.viewport.color as color
import arm.viewport.compositor as compositor
import arm.viewport.context as context
import arm.viewport.files as files
import arm.viewport.raster.lighting as lighting
import arm.viewport.raster.materials as materials
import arm.viewport.mx_export as mx_export
import arm.viewport.raster.settings as settings
import arm.linked_utils as linked_utils
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    color = arm.reload_module(color)
    compositor = arm.reload_module(compositor)
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    lighting = arm.reload_module(lighting)
    materials = arm.reload_module(materials)
    mx_export = arm.reload_module(mx_export)
    settings = arm.reload_module(settings)
    linked_utils = arm.reload_module(linked_utils)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

# Scene export name -> {'lut': table file, 'settings': settings file}
SCENE_INDEX = 'vpraster_scenes.json'


def build():
    assets.add_khafile_def('rp_renderer=ViewportRaster')
    # Shared Iron code tests these old render path features with `!= "Off"`,
    # which is true when they are not defined at all.
    assets.add_khafile_def('rp_voxels=Off')
    assets.add_khafile_def('rp_ssgi=Off')
    # No arm_veloc: last frame's world matrices are RasterUniforms' own (recorded once
    # per frame), not MeshObject.prevMatrix, which changes after every draw call
    assets.add_shader_pass('vpraster_world_pass')
    assets.add_shader_pass('vpraster_blend_pass')
    # Glare node passes (ViewportCompositor)
    for glare_pass in ('prefilter', 'firefly', 'down', 'up', 'bloom', 'streak', 'star', 'sun', 'finish'):
        assets.add_shader_pass('viewport_glare_' + glare_pass)
    assets.add_shader_pass('vpraster_taa_pass')
    assets.add_shader_pass('vpraster_film_pass')
    # Shared shader code (#include "vpraster_common.inc"), next to the passes that include it.
    # khamake only compares a shader with its own output, so a changed include is
    # passed on by touching the shaders (as for compiled.inc in make.export_data())
    if arm.utils.copy_file_if_changed(files.sdk_shaders('vpraster_common.inc'),
                                      os.path.join(files.build_shaders(), 'vpraster_common.inc')):
        assets.invalidate_shader_compilation()
    # Eevee's measured specular tables (Shaders/vpraster/vpraster_specular.glsl): reflectance, lamp lobe
    for table in ('vpraster_dfg.bin', 'vpraster_ltc.bin'):
        assets.add(files.sdk_shaders(table))
    build_scene_settings()
    # Materials as MaterialX documents (cached per material)
    mx_export.build()
    # One lighting pass for every material
    lighting.build()


def finish():
    """After the scenes are exported (make.export_data()): the build folder is
    kept between builds, so the material shaders no scene uses are deleted."""
    materials.prune()


def build_scene_settings():
    """Bakes the colour management and writes the Eevee settings of every exported
    scene, with its compositor shader (compositor.py); like Blender, each scene
    keeps its own and the render path switches to the active scene's at runtime. Scenes with the same colour management share a table."""
    folder = files.build_assets()
    os.makedirs(folder, exist_ok=True)
    index = {}
    written = {SCENE_INDEX}
    compositors = set()
    for scene in context.exported_scenes():
        name = linked_utils.get_scene_name(scene)

        # Named after the colour settings: scenes that share them share a table, and
        # an unchanged table is not baked again. The table is baked before its file
        # is written: a failed bake leaves no file that later builds would trust
        table_file = 'viewport_film_lut_%s.bin' % color.settings_key(scene)
        if table_file not in written:
            written.add(table_file)
            table_path = os.path.join(folder, table_file)
            if not os.path.isfile(table_path) or os.path.getsize(table_path) == 0:
                files.write_if_changed(table_path, color.build(scene, os.path.join(folder, '_viewport_lut_grid.png')))
            assets.add(table_path)

        settings_file = 'vpraster_settings_%s.json' % arm.utils.safesrc(name)
        written.add(settings_file)
        steps, shaders = compositor.build(scene)
        compositors |= shaders
        settings.write(scene, os.path.join(folder, settings_file), steps)
        assets.add(os.path.join(folder, settings_file))
        index[name] = {'lut': table_file, 'settings': settings_file}

    index_path = os.path.join(folder, SCENE_INDEX)
    files.write_if_changed(index_path, json.dumps(index, indent=1))
    assets.add(index_path)
    files.prune(folder, written, lambda name: name.startswith(('viewport_film_lut_', 'vpraster_settings_')))
    compositor.prune(compositors)
