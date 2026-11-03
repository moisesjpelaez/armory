"""Eevee render path: a renderer driven by Blender's own Eevee settings.

Selected with Renderer = Eevee. It never uses the Cycles node translation or the
Forward/Deferred render path settings; the rest of the exporter hands off to the
modules in this package at a few entry points.
"""
