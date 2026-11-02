"""Render path setup for the Eevee renderer (called from make_renderpath.build())."""
import hashlib
import json
import os

import bpy

import arm
import arm.assets as assets
import arm.eevee.color as color
import arm.eevee.settings as settings
import arm.linked_utils as linked_utils
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    color = arm.reload_module(color)
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
    assets.add_shader_pass('eevee_taa_pass')
    assets.add_shader_pass('eevee_film_pass')
    # Eevee's measured specular tables (glsl_rewrite.EEVEE_SPECULAR): reflectance, lamp lobe
    for table in ('eevee_dfg.bin', 'eevee_ltc.bin'):
        assets.add(os.path.join(arm.utils.get_sdk_path(), 'armory', 'Shaders', 'eevee', table))
    build_scene_settings()


def build_scene_settings():
    """Bakes the colour management and writes the Eevee settings of every exported
    scene; like Blender, each scene keeps its own and the render path switches to
    the active scene's at runtime. Scenes with the same colour management share a table."""
    folder = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Assets')
    os.makedirs(folder, exist_ok=True)
    index = {}
    tables = set()
    for scene in bpy.data.scenes:
        if not scene.arm_export:
            continue
        name = linked_utils.get_scene_name(scene)

        table = color.build(scene, os.path.join(folder, '_eevee_lut_grid.png'))
        table_file = 'eevee_film_lut_%s.bin' % hashlib.sha1(table).hexdigest()[:12]
        if table_file not in tables:
            tables.add(table_file)
            with open(os.path.join(folder, table_file), 'wb') as f:
                f.write(table)
            assets.add(os.path.join(folder, table_file))

        settings_file = 'eevee_settings_%s.json' % arm.utils.safesrc(name)
        settings.write(scene, os.path.join(folder, settings_file))
        assets.add(os.path.join(folder, settings_file))
        index[name] = {'lut': table_file, 'settings': settings_file}

    index_path = os.path.join(folder, SCENE_INDEX)
    with open(index_path, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=1)
    assets.add(index_path)
