"""The Viewport render paths: renderers that look like Blender's own.

The parts any of them use: materials exported to MaterialX by Blender
(mx_export), the scene's compositor (compositor), colour management (color),
the build's state (context) and build folders (files). Each renderer has a
subpackage: raster, Viewport (Eevee).
"""
