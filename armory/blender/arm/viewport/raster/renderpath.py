"""Render path setup for the Viewport renderer.

make_renderpath.build() calls build() in place of the Forward/Deferred setup. It
registers the render passes and shared shader files, writes each scene's
settings, colour table and compositor, exports the materials to MaterialX and
builds the lighting pass.
"""
import json
import os

import arm
import arm.assets as assets
import arm.viewport.color as color
import arm.viewport.compositor as compositor
import arm.viewport.context as context
import arm.viewport.files as files
import arm.viewport.raster.lighting as lighting
import arm.viewport.mx_export as mx_export
import arm.viewport.raster.settings as settings
import arm.viewport.raster.state as state
import arm.linked_utils as linked_utils
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    color = arm.reload_module(color)
    compositor = arm.reload_module(compositor)
    context = arm.reload_module(context)
    files = arm.reload_module(files)
    lighting = arm.reload_module(lighting)
    mx_export = arm.reload_module(mx_export)
    settings = arm.reload_module(settings)
    state = arm.reload_module(state)
    linked_utils = arm.reload_module(linked_utils)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

# Scene export name -> {'lut': table file, 'settings': settings file}
SCENE_INDEX = 'vpraster_scenes.json'


def build():
    assets.add_khafile_def('rp_renderer=' + arm.utils.VIEWPORT_RASTER)
    # Shared Iron code tests these old render path features with `!= "Off"`,
    # which is true when they are not defined at all.
    assets.add_khafile_def('rp_voxels=Off')
    assets.add_khafile_def('rp_ssgi=Off')
    # No arm_veloc define. Last frame's world matrices come from RasterUniforms,
    # which records them once per frame. MeshObject.prevMatrix can't be used: it
    # changes after every draw call.
    assets.add_shader_pass('vpraster_world_pass')
    assets.add_shader_pass('vpraster_blend_pass')
    # Glare node passes (ViewportCompositor)
    for glare_pass in ('prefilter', 'firefly', 'down', 'up', 'bloom', 'streak', 'star', 'sun', 'finish'):
        assets.add_shader_pass('viewport_glare_' + glare_pass)
    assets.add_shader_pass('vpraster_taa_pass')
    assets.add_shader_pass('vpraster_film_pass')
    # Shared shader code (vpraster_common.inc, viewport_glare.inc) is copied next to
    # the passes that #include it
    for include in (state.shaders('vpraster_common.inc'), files.sdk_shaders('.', 'viewport_glare.inc')):
        with open(include, encoding='utf-8') as f:
            files.write_if_changed(os.path.join(files.build_shaders(), os.path.basename(include)), f.read())
    # Lookup tables fitted to match Eevee: specular reflectance and the lamp
    # highlight lobe (see vpraster_specular.glsl)
    for table in ('vpraster_dfg.bin', 'vpraster_ltc.bin'):
        assets.add(state.shaders(table))
    build_scene_settings()
    # Materials as MaterialX documents (cached per material)
    mx_export.build()
    # The lighting pass all materials share, and the shadow pass
    lighting.build()


def build_scene_settings():
    """Writes the settings of every exported scene: its Eevee settings, its colour
    table (color.py) and its compositor shaders (compositor.py). As in Blender,
    each scene keeps its own settings, and the render path switches to the active
    scene's at runtime. Scenes with the same colour management share one table."""
    folder = files.build_assets()
    os.makedirs(folder, exist_ok=True)
    index = {}
    written = {SCENE_INDEX}
    compositors = set()
    for scene in context.exported_scenes():
        name = linked_utils.get_scene_name(scene)

        # The table is named after the colour settings. Scenes that share them share
        # a table, and an unchanged table is not baked again. The bake finishes
        # before the file is written, so a failed bake leaves no file that later
        # builds would trust.
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
