"""What in a node tree can change an export: shared by the Viewport renderers'
caches (mx_export's material hash, the world bakes), so none of them needs to
import another's exporter for it."""
import hashlib
import os

import bpy

import arm

if not arm.is_reload(__name__):
    arm.enable_reload(__name__)


def image_state(image) -> str:
    """What identifies an image's pixels: an edited file or a repacked image
    changes the material's hash, so the material is exported again."""
    if image.packed_file is not None:
        return 'packed:' + hashlib.sha1(image.packed_file.data).hexdigest()
    if image.source == 'FILE':
        path = bpy.path.abspath(image.filepath, library=image.library)
        if os.path.isfile(path):
            stat = os.stat(path)
            return 'file:%d:%d' % (stat.st_mtime_ns, stat.st_size)
        return 'missing'
    return ''


def tree_signature(tree, groups: dict) -> str:
    """Everything in a node tree that can change Blender's MaterialX export.
    `groups` keeps each node group's signature for the build
    (context.current().group_signatures): a group many materials use is read once."""
    parts = []
    included = set()
    # Inputs a link really feeds: a muted or invalid link leaves the input's own value in use
    fed = {(link.to_node.name, link.to_socket.identifier) for link in tree.links
           if link.is_valid and not link.is_muted}
    for node in sorted(tree.nodes, key=lambda n: n.name):
        parts.append('N%s|%s' % (node.name, node.bl_idname))
        for prop in node.bl_rna.properties:
            # Layout only. `mute` stays: a muted node passes its input through
            if prop.identifier in ('location', 'location_absolute', 'width', 'height', 'select', 'label', 'name',
                                   'dimensions', 'show_options', 'show_preview', 'hide', 'color',
                                   'use_custom_color', 'show_texture', 'warning_propagation'):
                continue
            if prop.type in ('STRING', 'ENUM', 'BOOLEAN', 'INT', 'FLOAT'):
                parts.append('%s=%r' % (prop.identifier, getattr(node, prop.identifier)))
        image = getattr(node, 'image', None)
        if image is not None:
            parts.append('IMG%s|%s|%s|%s' % (image.filepath, image.colorspace_settings.name, image.source,
                                             image_state(image)))
        if node.type == 'GROUP' and node.node_tree is not None and node.node_tree not in included:
            included.add(node.node_tree)  # the group itself: linked groups of the same name differ
            key = (node.node_tree.as_pointer(), node.node_tree.name_full)
            if key not in groups:
                groups[key] = tree_signature(node.node_tree, groups)
            parts.append('G{%s}' % groups[key])
        for socket in node.inputs:
            if (node.name, socket.identifier) not in fed and hasattr(socket, 'default_value'):
                value = socket.default_value
                parts.append('I%s=%r' % (socket.identifier, tuple(value) if hasattr(value, '__len__') else value))
    for link in tree.links:
        if link.is_valid and not link.is_muted:
            parts.append('L%s.%s>%s.%s' % (link.from_node.name, link.from_socket.identifier,
                                             link.to_node.name, link.to_socket.identifier))
    return ';'.join(parts)
