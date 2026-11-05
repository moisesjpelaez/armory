"""Viewport (Eevee): the raster renderer of the Viewport render paths.

Renders like Blender's Eevee, from Blender's own settings: materials as MaterialX
(G-buffer, then one lighting pass; Blended materials forward), Eevee's lights
and shadows, temporal anti-aliasing, the scene's colour management. Selected
with Renderer = Viewport (Eevee) (rp_renderer ViewportRaster). It never uses the
Cycles node translation or the Forward/Deferred render path settings; the rest
of the exporter hands off to the modules in this package at a few entry points.
"""
