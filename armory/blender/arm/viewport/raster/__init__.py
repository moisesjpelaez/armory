"""Viewport (Eevee): the raster renderer of the Viewport render paths.

It renders like Blender's Eevee, from Blender's own settings. Opaque materials
write their surface values into the material images (a G-buffer), and one
full-screen lighting pass lights them. Blended materials are lit in their own
shaders. It has Eevee's lights and soft shadows, temporal anti-aliasing and the
scene's colour management. It is selected with Renderer = Viewport (Eevee), which
sets rp_renderer to ViewportRaster. It never uses the Cycles node translation or
the Forward/Deferred render path settings: the exporter hands off to this package
at the few points listed below.

Build sequence, with the Armory hook that calls each step:
  1. make.py export_data() starts the build state (viewport/context.py begin()).
     state.py keeps this renderer's part of it.
  2. make_world.py build() calls world.py build(). Each world is rendered by
     Blender and baked into radiance and irradiance maps, and a sun is taken out
     of it if it has a sun threshold.
  3. make_renderpath.py build() calls renderpath.py build(). It registers the
     render passes, then for each scene writes the Eevee settings (settings.py),
     the colour table (viewport/color.py) and the compositor shaders
     (viewport/compositor.py). Then it exports the materials to MaterialX
     (viewport/mx_export.py) and builds the versions of the lighting and shadow
     passes (lighting.py).
  4. During the scene export, material/make.py parse() calls materials.py parse()
     for each material. It turns the material's MaterialX document into shaders
     (mx_graph.py, mx_codegen.py, glsl_rewrite.py, vertex.py). exporter.py calls
     world.py export() and lights.py export() to write the world and light fields.

engine.py reads sizes and names from the Haxe sources, so both sides agree.
"""
