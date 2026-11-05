"""Render path setup for the Eevee renderer (called from make_renderpath.build())."""
import json
import os

import bpy

import arm
import arm.assets as assets
import arm.eevee.color as color
import arm.eevee.compositor as compositor
import arm.eevee.files as files
import arm.eevee.lighting as lighting
import arm.eevee.mx_export as mx_export
import arm.eevee.settings as settings
import arm.linked_utils as linked_utils
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    color = arm.reload_module(color)
    compositor = arm.reload_module(compositor)
    files = arm.reload_module(files)
    lighting = arm.reload_module(lighting)
    mx_export = arm.reload_module(mx_export)
    settings = arm.reload_module(settings)
    linked_utils = arm.reload_module(linked_utils)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

# Scene export name -> {'lut': table file, 'settings': settings file}
SCENE_INDEX = 'eevee_scenes.json'


def build():
    assets.add_khafile_def('rp_renderer=Eevee')
    # Shared Iron code tests these old render path features with `!= "Off"`,
    # which is true when they are not defined at all.
    assets.add_khafile_def('rp_voxels=Off')
    assets.add_khafile_def('rp_ssgi=Off')
    # Meshes keep last frame's world matrix (MeshObject.prevMatrix) for velocity
    assets.add_khafile_def('arm_veloc')
    assets.add_shader_pass('eevee_world_pass')
    assets.add_shader_pass('eevee_blend_pass')
    # Glare node passes (EeveeCompositor)
    for glare_pass in ('prefilter', 'firefly', 'down', 'up', 'bloom', 'streak', 'star', 'sun', 'finish'):
        assets.add_shader_pass('eevee_glare_' + glare_pass)
    assets.add_shader_pass('eevee_taa_pass')
    assets.add_shader_pass('eevee_film_pass')
    # Shared shader code (#include "eevee_common.inc"), next to the shaders that include it
    with open(files.sdk_shaders('eevee_common.inc'), encoding='utf-8') as f:
        files.write_if_changed(os.path.join(files.build_shaders(), 'eevee_common.inc'), f.read())
    # Eevee's measured specular tables (Shaders/eevee/eevee_specular.glsl): reflectance, lamp lobe
    for table in ('eevee_dfg.bin', 'eevee_ltc.bin'):
        assets.add(files.sdk_shaders(table))
    build_scene_settings()
    # Materials as MaterialX documents (cached per material)
    mx_export.build()
    # One lighting pass for every material
    lighting.build()


def build_scene_settings():
    """Bakes the colour management and writes the Eevee settings of every exported
    scene, with its compositor shader (compositor.py); like Blender, each scene
    keeps its own and the render path switches to the active scene's at runtime. Scenes with the same colour management share a table."""
    folder = files.build_assets()
    os.makedirs(folder, exist_ok=True)
    index = {}
    written = {SCENE_INDEX}
    compositors = set()
    for scene in bpy.data.scenes:
        if not scene.arm_export:
            continue
        name = linked_utils.get_scene_name(scene)

        # Named after the colour settings: scenes that share them share a table, and
        # an unchanged table is not baked again
        table_file = 'eevee_film_lut_%s.bin' % color.settings_key(scene)
        if table_file not in written:
            written.add(table_file)
            if not os.path.isfile(os.path.join(folder, table_file)):
                with open(os.path.join(folder, table_file), 'wb') as f:
                    f.write(color.build(scene, os.path.join(folder, '_eevee_lut_grid.png')))
            assets.add(os.path.join(folder, table_file))

        settings_file = 'eevee_settings_%s.json' % arm.utils.safesrc(name)
        written.add(settings_file)
        steps, shaders = compositor.build(scene)
        compositors |= shaders
        settings.write(scene, os.path.join(folder, settings_file), steps)
        assets.add(os.path.join(folder, settings_file))
        index[name] = {'lut': table_file, 'settings': settings_file}

    index_path = os.path.join(folder, SCENE_INDEX)
    with open(index_path, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=1)
    assets.add(index_path)
    files.prune(folder, written, lambda name: name.startswith(('eevee_film_lut_', 'eevee_settings_')))
    compositor.prune(compositors)
