"""The Viewport render paths: renderers that make the game look like Blender's viewport.

This is the Python side, which runs in Blender during an Armory build. It reads
Blender's own settings, not Armory's render path settings. It exports every
material as a MaterialX document, bakes the world lighting and the scene's colour
management, turns the compositor node tree into shaders, and writes the shaders
and settings files that the Haxe side (armory.renderpath.viewport) loads at runtime.

The code is split in two levels:
  viewport/          What any Viewport renderer would share: the MaterialX export
                     (mx_export.py), the compositor (compositor.py), colour
                     management (color.py), the build state (context.py), build
                     folders and file writes (files.py), the GLSL preprocessor and
                     readers (glsl.py), and node tree signatures for the caches
                     (signature.py).
  viewport/raster/   The raster renderer, Renderer = Viewport (Eevee). It is kept
                     apart so that a second Viewport renderer can be added next to
                     it and reuse the shared modules.
File names follow the same split: names starting with `viewport_` are shared,
names starting with `vpraster_` belong to the raster renderer.

A build runs in this order (arm/make.py export_data()):
  1. make.py calls context.begin(), which starts the build state.
  2. make_world.py calls raster/world.py build(): it bakes the world lighting.
  3. make_renderpath.py calls raster/renderpath.py build(): scene settings, colour
     table and compositor per scene, then the MaterialX export (mx_export.py),
     then the lighting and shadow pass versions (raster/lighting.py).
  4. The exporter exports each scene. material/make.py calls raster/materials.py
     parse() for each material; exporter.py calls raster/world.py export() and
     raster/lights.py export() to write the world and light fields.
  5. make.py calls raster/renderpath.py finish(), which deletes the material
     shaders no scene uses any more.
"""
