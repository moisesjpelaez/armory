"""Warnings about what Blender's MaterialX export loses (Viewport renderer).

Blender's USD exporter does not export every shader node to MaterialX. Some
nodes are left out, some become a wrong constant, and every colour blend mode
becomes a plain mix. mx_export.build() calls report_unexported() for every
material, so each such node is reported once per material. The node's output is
whatever Blender exported.

display_name() is the name a material has in every message of the renderer.
"""
import arm
import arm.viewport.context as context
import arm.linked_utils as linked_utils
import arm.log as log

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    linked_utils = arm.reload_module(linked_utils)
    log = arm.reload_module(log)
else:
    arm.enable_reload(__name__)

# Blender nodes that its MaterialX export loses, or turns into a wrong constant
NOT_EXPORTED = {
    'VERTEX_COLOR': 'Color Attribute', 'ATTRIBUTE': 'Attribute', 'OBJECT_INFO': 'Object Info',
    'VALTORGB': 'Color Ramp', 'TEX_VORONOI': 'Voronoi Texture', 'TEX_BRICK': 'Brick Texture',
    'TEX_MAGIC': 'Magic Texture', 'MIX_RGB': 'Mix (Legacy)', 'PARTICLE_INFO': 'Particle Info',
}
WRONG_CONSTANT = {'FRESNEL': 'Fresnel', 'LAYER_WEIGHT': 'Layer Weight', 'BLACKBODY': 'Blackbody'}
# Mix node colour blend modes that Blender exports as a plain mix -> the MaterialX
# node that mx_extract.restore_blend_modes() puts back. Other modes keep a warning.
BLEND_MODES = {'MULTIPLY': 'multiply'}


def display_name(material) -> str:
    """The material's name in messages: linked materials carry their library's suffix."""
    return linked_utils.asset_name(material)


def report_missing(wanted: dict):
    """Warns about the materials mx_export.export() could not write (what it returns)."""
    for material, _ in wanted.values():
        log.warn('Viewport renderer: material "%s" was not exported to MaterialX by Blender' % display_name(material))


def report_unexported(material):
    """Warns, once per material, about nodes that Blender's MaterialX export loses
    or gets wrong, inside node groups too."""
    if material.node_tree is None or not context.warn_once('export', display_name(material)):
        return
    found = {}

    def visit(tree):
        for node in tree.nodes:
            if node.type == 'GROUP' and node.node_tree is not None:
                visit(node.node_tree)
            elif node.type in NOT_EXPORTED or node.type in WRONG_CONSTANT:
                found[node.type] = node.name
            elif (node.type == 'MIX' and node.data_type == 'RGBA' and node.blend_type != 'MIX'
                  and (tree is not material.node_tree or node.blend_type not in BLEND_MODES)):
                # Blender exports every colour blend mode as a plain mix.
                # mx_extract.restore_blend_modes() restores the ones in BLEND_MODES.
                log.warn('Viewport renderer: material "%s": the Mix node ("%s") is exported by Blender as a plain '
                         'Mix, its %s blend mode is lost' % (display_name(material), node.name,
                                                             node.bl_rna.properties['blend_type'].enum_items[node.blend_type].name))
            elif (node.type == 'NORMAL_MAP' and node.space == 'TANGENT' and node.inputs['Color'].is_linked
                  and (node.inputs['Strength'].is_linked or node.inputs['Strength'].default_value > 0.0)):
                # Meshes are exported without tangents. The vertex stage builds one
                # from the normal, which is not the UV tangent.
                log.warn('Viewport renderer: material "%s": the Normal Map node ("%s") needs mesh tangents, '
                         'which are not exported; it renders with the wrong orientation'
                         % (display_name(material), node.name))
    visit(material.node_tree)
    for node_type in sorted(found):
        if node_type in NOT_EXPORTED:
            log.warn('Viewport renderer: material "%s": the %s node ("%s") is not exported to MaterialX by Blender; '
                     'its output is replaced by a constant' % (display_name(material), NOT_EXPORTED[node_type],
                                                               found[node_type]))
        else:
            log.warn('Viewport renderer: material "%s": the %s node ("%s") is exported by Blender as a constant '
                     'that does not match Eevee' % (display_name(material), WRONG_CONSTANT[node_type], found[node_type]))
