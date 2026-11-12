"""A material's AOV Output nodes, as materials Blender can export (Viewport renderer).

Blender's MaterialX export leaves AOV Outputs out. So mx_export.build_aovs()
exports each AOV from a temporary copy of its material, whose emission is the
AOV's input (aov_material()). aov_outputs() finds the AOV Output nodes of a
material.
"""
import arm
import arm.viewport.context as context
import arm.viewport.mx_report as mx_report
import arm.log as log

if arm.is_reload(__name__):
    context = arm.reload_module(context)
    mx_report = arm.reload_module(mx_report)
    log = arm.reload_module(log)
else:
    arm.enable_reload(__name__)


def aov_outputs(material) -> dict:
    """The AOV Output nodes in the material's own tree, by AOV name. AOV Outputs
    inside node groups are not supported and get a warning."""
    outputs = {}
    for node in sorted(material.node_tree.nodes, key=lambda n: n.name):
        if node.type != 'OUTPUT_AOV' or node.mute or not node.aov_name:
            continue
        if node.aov_name in outputs:
            if context.warn_once('aov twice', '%s/%s' % (mx_report.display_name(material), node.aov_name)):
                log.warn('Viewport renderer: material "%s" has several AOV Outputs named "%s"; only "%s" is used'
                         % (mx_report.display_name(material), node.aov_name, outputs[node.aov_name].name))
            continue
        outputs[node.aov_name] = node

    def in_groups(tree, seen):
        for node in tree.nodes:
            if node.type == 'GROUP' and node.node_tree is not None and node.node_tree not in seen:
                seen.add(node.node_tree)
                if any(n.type == 'OUTPUT_AOV' for n in node.node_tree.nodes) or in_groups(node.node_tree, seen):
                    return True
        return False
    if in_groups(material.node_tree, set()) and context.warn_once('aov group', mx_report.display_name(material)):
        log.warn('Viewport renderer: material "%s": AOV Outputs inside node groups are not supported; '
                 'put them in the material itself' % mx_report.display_name(material))
    return outputs


def aov_material(material, node, aov_type: str, name: str):
    """A copy of the material whose emission is the AOV Output's input (Color or
    Value, by the AOV's type). The copy keeps nothing else of the material but
    its alpha. The AOV's pass writes the emission as the AOV (materials.py) and,
    as in Eevee, leaves out the pixels the material leaves out (Dithered alpha)."""
    copy = material.copy()
    copy.name = name
    tree = copy.node_tree
    source = tree.nodes[node.name].inputs['Color' if aov_type == 'COLOR' else 'Value']
    output = tree.get_output_node('EEVEE')
    if output is None:
        output = tree.nodes.new('ShaderNodeOutputMaterial')
    surface = output.inputs['Surface'].links[0].from_node if output.inputs['Surface'].is_linked else None
    if surface is not None and surface.type == 'BSDF_PRINCIPLED':
        for link in list(tree.links):
            if link.to_node == surface and link.to_socket.identifier != 'Alpha':
                tree.links.remove(link)
        surface.inputs['Emission Strength'].default_value = 1.0
        target = surface.inputs['Emission Color']
    else:
        emission = tree.nodes.new('ShaderNodeEmission')
        emission.inputs['Strength'].default_value = 1.0
        tree.links.new(emission.outputs[0], output.inputs['Surface'])
        target = emission.inputs['Color']
    if source.is_linked:
        tree.links.new(source.links[0].from_socket, target)
    else:
        value = source.default_value
        target.default_value = tuple(value) if aov_type == 'COLOR' else (value, value, value, 1.0)
    return copy
