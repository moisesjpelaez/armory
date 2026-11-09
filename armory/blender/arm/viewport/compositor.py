"""Blender's compositor for the Viewport renderer: a subset of its nodes, per scene.

As in Blender, a scene composites its render when Output Properties > Post
Processing > Compositing is on and the scene has a compositor node tree. build()
turns the tree into steps (Program). ViewportCompositor draws them after the
blended materials and before temporal anti-aliasing. Like Blender's compositor,
they work on scene-linear colour; the film pass applies the view transform
afterwards. The nodes are generated together into full-screen shaders (stages).
A Glare node is drawn by fixed passes (Shaders/viewport_glare_*), so it splits
the tree into the stages before and after it.

Supported nodes: Render Layers (Image, Alpha, Depth, Transparent and the AOVs),
Group Output, Reroute, Value, RGB, Math, Mix (Float and Color), Map Range
(Float), Color Ramp (RGB: Linear, Constant, Ease), Separate and Combine Color
(RGB), Glare (Bloom, Streaks, Simple Star, Sun Beams). Nodes the output doesn't
reach (such as a Viewer) are ignored. A tree that needs any other node is
reported, and the scene renders without its compositor.

Values follow Blender:
  - Colour to float is the Rec.709 luminance; float to colour is (v, v, v, 1).
  - Depth is the distance along the view direction to the nearest opaque
    surface (blended surfaces are left out), and 1e10 for the sky.
  - Transparent is the blended surfaces' colour, premultiplied, with their
    coverage in alpha.
"""
import hashlib
import os
import re

import arm
import arm.assets as assets
import arm.viewport.files as files
import arm.viewport.mx_export as mx_export
import arm.log as log
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    files = arm.reload_module(files)
    mx_export = arm.reload_module(mx_export)
    log = arm.reload_module(log)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

PREFIX = 'viewport_comp_'  # shader name: PREFIX + hash of its source
RESULT = 'viewport_composite'  # the target of the last stage

# Sampler names of the Render Layers passes. The renderer gives ViewportCompositor
# the target of each. AOVs are named 'aov' + their index in the scene's AOVs.
IMAGE, TRANSPARENT, DEPTH = 'image', 'transparent', 'depth'


def is_render_pass(sampler: str) -> bool:
    """Whether a sampler reads a render pass, rather than an earlier step's target."""
    return sampler in (IMAGE, TRANSPARENT, DEPTH) or re.fullmatch(r'aov\d+', sampler) is not None


def target_name(sampler: str) -> str:
    """The target of a compositor step, read by later stages as `sampler`."""
    return 'viewport_' + sampler
# Uniforms the engine fills, for the Depth pass: name -> (shader data type, link)
CONSTANTS = {
    'invVP': ('mat4', '_inverseViewProjectionMatrix'),
    'cameraPosition': ('vec3', '_cameraPosition'),
    'cameraLook': ('vec3', '_cameraLook'),
}
GLSL_TYPES = {'float': 'float', 'color': 'vec4'}


class Unsupported(Exception):
    pass


def build(scene) -> tuple:
    """Writes the scene's compositor shaders. Returns (the plan for
    ViewportCompositor, the shader names), or (None, set()) when the scene doesn't
    composite or its tree isn't supported. The plan's keys (Haxe:
    ViewportCompositor.TCompositor):
      steps   The steps in drawing order. Every target name is resolved here
              (see ViewportTargets).
      passes  The render passes the stages read. The renderer draws an AOV, or
              clears the Transparent image, only when it is listed.
      result  The target of the last stage."""
    tree = scene.compositing_node_group
    if not scene.render.use_compositing or tree is None:
        return None, set()
    output = next((n for n in tree.nodes if n.type == 'GROUP_OUTPUT' and n.is_active_output), None)
    if output is None or not output.inputs:
        return None, set()
    program = Program(scene)
    try:
        program.stage(output.inputs[0], None)
    except Unsupported as problem:
        log.warn('Viewport renderer: scene "%s": the compositor is not supported (%s); the scene renders '
                 'without it' % (scene.name, problem))
        return None, set()
    shaders = {step['shader'] for step in program.steps if step['kind'] == 'stage'}
    passes = sorted({name for step in program.steps if step['kind'] == 'stage' for name in step['passes']})
    return {'steps': program.steps, 'passes': passes, 'result': RESULT}, shaders


class Program:
    """A scene's compositor as steps, in the order ViewportCompositor draws them.
    There are two kinds of step:
      - stages: generated shaders, each drawn into a target (the last one into
        the result)
      - Glare nodes, drawn by fixed passes
    A Glare node splits the tree. What feeds its Image input becomes a stage of
    its own (unless it is the render's Image), and nodes that read the glare's
    outputs sample the glare's targets."""

    def __init__(self, scene):
        self.scene = scene
        aovs = mx_export.scene_aovs(scene)
        self.aov_names = [name for name, _ in aovs]
        self.aov_types = dict(aovs)
        self.steps = []
        self.glares = {}  # Glare node name -> (index, input: 'image' or its stage's target)

    def stage(self, socket, target: str) -> None:
        """Adds a stage that draws `socket`'s colour into `target`. `target` is the
        sampler name later stages read it by, or None for the result. The stage
        lists what it reads: render passes by name, and earlier steps' targets as
        [sampler, target]."""
        generator = Generator(self)
        result = generator.value(socket, 'color')
        name = write_shader(generator.source(result), generator)
        samplers = sorted(generator.samplers)
        self.steps.append({'kind': 'stage', 'shader': name, 'target': target_name(target) if target else RESULT,
                           'passes': [s for s in samplers if is_render_pass(s)],
                           'targets': [[s, target_name(s)] for s in samplers if not is_render_pass(s)]})

    def glare(self, node) -> tuple:
        """(index, input) of a Glare node. Its steps are added the first time it is asked for."""
        if node.name not in self.glares:
            settings = glare_settings(node, self.scene)
            index = len(self.glares)
            source = node.inputs['Image']
            link = source.links[0] if source.is_linked and source.links[0].is_valid and not source.links[0].is_muted else None
            if (link is not None and link.from_node.type == 'R_LAYERS' and link.from_socket.name == 'Image'
                    and not link.from_node.mute and link.from_node.scene in (None, self.scene)):
                image = 'image'  # the render itself: no stage needed
            else:
                image = 'glare%d_in' % index
                self.stage(source, image)
            glare = 'glare%d' % index
            self.steps.append(dict(settings, kind='glare', index=index,
                                   input=image if image == IMAGE else target_name(image),
                                   highlights=target_name(glare + '_hl'), output=target_name(glare)))
            self.glares[node.name] = (index, image)
        return self.glares[node.name]


QUALITY = {'High': 1, 'Medium': 2, 'Low': 4}  # the glare's resolution divider


GLARE_TYPES = ('Bloom', 'Streaks', 'Simple Star', 'Sun Beams')


def glare_settings(node, scene) -> dict:
    """The Glare node's settings for ViewportCompositor. In Blender, Streaks and
    Simple Star have lengths in pixels of the render (at the node's Quality).
    `render_size`, the render's smaller side, lets the game scale them to its window."""
    def setting(identifier):
        socket = next(s for s in node.inputs if s.identifier == identifier)
        if socket.is_linked:
            raise Unsupported('the Glare node "%s" with its %s connected' % (node.name, socket.name))
        return socket.default_value
    kind = setting('Type')
    if kind not in GLARE_TYPES:
        raise Unsupported('the Glare node\'s %s type' % kind)
    tint = setting('Tint')
    render = scene.render
    settings = {
        'glare': kind.lower().replace(' ', '_'),
        'quality': QUALITY[setting('Quality')],
        'threshold': float(setting('Highlights Threshold')),
        'smoothness': float(setting('Highlights Smoothness')),
        'maximum': float(setting('Maximum Highlights')) if setting('Clamp Highlights') else -1.0,
        'strength': float(setting('Strength')),
        'saturation': float(setting('Saturation')),
        'tint': [float(tint[0]), float(tint[1]), float(tint[2])],
        'render_size': min(render.resolution_x, render.resolution_y) * render.resolution_percentage / 100.0,
    }
    if kind in ('Bloom', 'Sun Beams'):
        settings['size'] = float(setting('Size'))
    if kind in ('Streaks', 'Simple Star'):
        # Blender treats Iterations below 2 as 2, and Fade below 0.75 as 0.75
        settings['iterations'] = max(int(setting('Iterations')), 2)
        settings['fade'] = min(max(float(setting('Fade')), 0.75), 1.0)
    if kind == 'Streaks':
        settings['streaks'] = max(int(setting('Streaks')), 1)
        settings['angle'] = float(setting('Streaks Angle'))
        settings['color_modulation'] = float(setting('Color Modulation'))
    if kind == 'Simple Star':
        settings['diagonal'] = bool(setting('Diagonal Star'))
    if kind == 'Sun Beams':
        position = setting('Sun Position')
        settings['sun_position'] = [float(position[0]), float(position[1])]
    return settings


def write_shader(frag: str, generator) -> str:
    """Writes a stage's pixel shader and shader data, and returns the shader's name."""
    name = PREFIX + hashlib.sha1(frag.encode()).hexdigest()[:12]
    build_shaders = files.build_shaders()
    files.write_if_changed(os.path.join(build_shaders, name + '.frag.glsl'), frag)
    context = {
        'name': name,
        'depth_write': False,
        'compare_mode': 'always',
        'cull_mode': 'none',
        'vertex_elements': [{'name': 'pos', 'data': 'float2'}],
        'color_attachments': ['RGBA64'],
        'vertex_shader': 'pass.vert',
        'fragment_shader': name + '.frag',
        'texture_units': [{'name': sampler} for sampler in sorted(generator.samplers)],
        'constants': [{'name': n, 'type': t, 'link': link} for n, (t, link) in sorted(CONSTANTS.items())
                      if n in generator.constants],
    }
    path = os.path.join(build_shaders, name + '.arm')
    arm.utils.write_arm(path, {'shader_datas': [{'name': name, 'contexts': [context]}]})
    assets.add_shader_data(path)
    return name


def prune(names: set):
    """Deletes the compositor shaders no scene uses any more."""
    files.prune(files.build_shaders(), set(), lambda file: file.startswith(PREFIX) and file.split('.')[0] not in names)


def number(value: float) -> str:
    return repr(float(value))


def vec4(values) -> str:
    values = list(values) + [1.0] * (4 - len(values))
    return 'vec4(%s)' % ', '.join(number(v) for v in values[:4])


def convert(expr: str, kind: str, want: str) -> str:
    """Converts a GLSL value between 'float' and 'color' as Blender does (see the module docstring)."""
    if kind == want:
        return expr
    if kind == 'float' and want == 'color':
        return 'vec4(vec3(%s), 1.0)' % expr
    if kind == 'color' and want == 'float':
        return 'dot((%s).rgb, vec3(0.2126, 0.7152, 0.0722))' % expr
    raise Unsupported('%s to %s conversion' % (kind, want))


def socket_by_id(sockets, identifier: str):
    """A node socket by identifier. Indexing by key would find it by name instead."""
    return next(socket for socket in sockets if socket.identifier == identifier)


def socket_kind(socket) -> str:
    if socket.type == 'RGBA':
        return 'color'
    if socket.type in ('VALUE', 'INT', 'BOOLEAN'):
        return 'float'
    raise Unsupported('%s sockets (%s)' % (socket.type.lower(), socket.name))


# Math node operations, as defined in Blender's manual, on the inputs a, b and c.
# Where an operation is undefined (division by zero and so on), the result is 0.
MATH = {
    'ADD': 'a + b', 'SUBTRACT': 'a - b', 'MULTIPLY': 'a * b', 'DIVIDE': '(b != 0.0 ? a / b : 0.0)',
    'MULTIPLY_ADD': 'a * b + c', 'POWER': 'arm_pow(a, b)',
    'LOGARITHM': '(a > 0.0 && b > 0.0 && b != 1.0 ? log(a) / log(b) : 0.0)',
    'SQRT': '(a > 0.0 ? sqrt(a) : 0.0)', 'INVERSE_SQRT': '(a > 0.0 ? inversesqrt(a) : 0.0)',
    'ABSOLUTE': 'abs(a)', 'EXPONENT': 'exp(a)', 'MINIMUM': 'min(a, b)', 'MAXIMUM': 'max(a, b)',
    'LESS_THAN': '(a < b ? 1.0 : 0.0)', 'GREATER_THAN': '(a > b ? 1.0 : 0.0)', 'SIGN': 'sign(a)',
    'COMPARE': '(abs(a - b) <= max(c, 1e-5) ? 1.0 : 0.0)', 'ROUND': 'floor(a + 0.5)', 'FLOOR': 'floor(a)',
    'CEIL': 'ceil(a)', 'TRUNC': 'trunc(a)', 'FRACT': '(a - floor(a))',
    'MODULO': '(b != 0.0 ? a - b * trunc(a / b) : 0.0)', 'FLOORED_MODULO': '(b != 0.0 ? a - b * floor(a / b) : 0.0)',
    'SNAP': '(b != 0.0 ? floor(a / b) * b : 0.0)', 'SINE': 'sin(a)', 'COSINE': 'cos(a)', 'TANGENT': 'tan(a)',
    'ARCSINE': '(a >= -1.0 && a <= 1.0 ? asin(a) : 0.0)', 'ARCCOSINE': '(a >= -1.0 && a <= 1.0 ? acos(a) : 0.0)',
    'ARCTANGENT': 'atan(a)', 'ARCTAN2': 'atan(a, b)', 'SINH': 'sinh(a)', 'COSH': 'cosh(a)', 'TANH': 'tanh(a)',
    'RADIANS': 'radians(a)', 'DEGREES': 'degrees(a)',
}

# Mix node colour blend modes: the blended colour of a and b, which is then mixed
# with a by the factor. As in Blender, the alpha is a's, except for the Mix mode,
# which mixes the alpha too.
BLENDS = {
    'ADD': 'a.rgb + b.rgb', 'SUBTRACT': 'a.rgb - b.rgb', 'MULTIPLY': 'a.rgb * b.rgb',
    'SCREEN': '1.0 - (1.0 - a.rgb) * (1.0 - b.rgb)', 'DIFFERENCE': 'abs(a.rgb - b.rgb)',
    'DARKEN': 'min(a.rgb, b.rgb)', 'LIGHTEN': 'max(a.rgb, b.rgb)',
}

# GLSL helpers a stage includes when a node needs them. arm_pow is the Math node's
# Power, which allows a negative base only with a whole exponent. arm_depth is the
# Depth pass (see the module docstring).
FUNCTIONS = {
    'arm_pow': 'float arm_pow(float a, float b) {\n'
               '    if (a >= 0.0) return pow(a, b);\n'
               '    return b == floor(b) ? (mod(b, 2.0) == 0.0 ? pow(-a, b) : -pow(-a, b)) : 0.0;\n'
               '}',
    'arm_depth': 'float arm_depth() {\n'
                 '    float d = textureLod(depth, texCoord, 0.0).r;\n'
                 '    if (d == 1.0) return 1e10;\n'
                 '    vec2 ndc = texCoord * 2.0 - 1.0;\n'
                 '#ifdef _InvY\n'
                 '    ndc.y = -ndc.y;\n'
                 '#endif\n'
                 '    vec4 world = invVP * vec4(ndc, d * 2.0 - 1.0, 1.0);\n'
                 '    return dot(world.xyz / world.w - cameraPosition, cameraLook);\n'
                 '}',
}


class Generator:
    """Generates the GLSL of one stage from the nodes its output reaches, with one
    variable per node output."""

    def __init__(self, program: Program):
        self.program = program
        self.scene = program.scene
        self.aov_names = program.aov_names
        self.aov_types = program.aov_types
        self.lines = []
        self.outputs = {}       # (node name, output identifier) -> (variable, kind)
        self.samplers = set()
        self.constants = set()
        self.functions = []

    def source(self, result: str) -> str:
        parts = ['#version 450', '#include "compiled.inc"', '', 'in vec2 texCoord;']
        parts += ['uniform sampler2D %s;' % s for s in sorted(self.samplers)]
        parts += ['uniform %s %s;' % (CONSTANTS[c][0], c) for c in sorted(self.constants)]
        parts += ['out vec4 fragColor;', '']
        parts += [FUNCTIONS[f] + '\n' for f in self.functions]
        parts += ['void main() {'] + ['    ' + line for line in self.lines]
        parts += ['    fragColor = %s;' % result, '}', '']
        return '\n'.join(parts)

    def function(self, name: str):
        if name not in self.functions:
            self.functions.append(name)

    def variable(self, kind: str, expr: str) -> str:
        name = 'v%d' % len(self.lines)
        self.lines.append('%s %s = %s;' % (GLSL_TYPES[kind], name, expr))
        return name

    def sample(self, sampler: str) -> str:
        self.samplers.add(sampler)
        return 'textureLod(%s, texCoord, 0.0)' % sampler

    def value(self, socket, want: str) -> str:
        """GLSL of an input socket's value, as `want` ('float' or 'color')."""
        link = socket.links[0] if socket.is_linked else None
        if link is not None and link.is_valid and not link.is_muted:
            expr, kind = self.output(link.from_socket)
            return convert(expr, kind, want)
        if not hasattr(socket, 'default_value'):
            raise Unsupported('unconnected %s input of "%s"' % (socket.name, socket.node.name))
        default = socket.default_value
        if socket_kind(socket) == 'color':
            return convert(vec4(default), 'color', want)
        return convert(number(default), 'float', want)

    def output(self, socket) -> tuple:
        """(GLSL variable, kind) of a node output."""
        key = (socket.node.name, socket.identifier)
        if key not in self.outputs:
            self.outputs[key] = self.evaluate(socket.node, socket)
        return self.outputs[key]

    def evaluate(self, node, socket) -> tuple:
        if node.mute:
            # Blender passes a muted node's matching input through
            link = next((l for l in node.internal_links if l.to_socket == socket), None)
            kind = socket_kind(socket)
            if link is None:
                return self.variable(kind, '0.0' if kind == 'float' else 'vec4(0.0)'), kind
            return self.variable(kind, self.value(link.from_socket, kind)), kind
        handler = getattr(self, 'node_' + node.type.lower(), None)
        if handler is None:
            raise Unsupported('the %s node "%s"' % (node.bl_label, node.name))
        return handler(node, socket)

    def node_reroute(self, node, socket):
        kind = socket_kind(socket)
        return self.variable(kind, self.value(node.inputs[0], kind)), kind

    def node_value(self, node, socket):
        return number(socket.default_value), 'float'

    def node_rgb(self, node, socket):
        return vec4(socket.default_value), 'color'

    def node_r_layers(self, node, socket):
        if node.scene is not None and node.scene != self.scene:
            raise Unsupported('Render Layers of another scene ("%s")' % node.scene.name)
        name = socket.name
        if name == 'Image':
            return self.variable('color', self.sample(IMAGE)), 'color'
        if name == 'Alpha':
            return self.variable('float', self.sample(IMAGE) + '.a'), 'float'
        if name == 'Transparent':
            return self.variable('color', self.sample(TRANSPARENT)), 'color'
        if name == 'Depth':
            self.samplers.add(DEPTH)
            self.constants.update(CONSTANTS)
            self.function('arm_depth')
            return self.variable('float', 'arm_depth()'), 'float'
        if name in self.aov_types:
            texel = self.sample('aov%d' % self.aov_names.index(name))
            if self.aov_types[name] == 'COLOR':
                return self.variable('color', texel), 'color'
            return self.variable('float', texel + '.r'), 'float'
        raise Unsupported('the %s pass' % name)

    def node_math(self, node, socket):
        if node.operation not in MATH:
            raise Unsupported('the Math node\'s %s operation' % node.operation.title().replace('_', ' '))
        if node.operation == 'POWER':
            self.function('arm_pow')
        names = {name: self.variable('float', self.value(node.inputs[i], 'float')) for i, name in enumerate('abc')}
        expr = re.sub(r'\b[abc]\b', lambda m: names[m.group(0)], MATH[node.operation])
        if node.use_clamp:
            expr = 'clamp(%s, 0.0, 1.0)' % expr
        return self.variable('float', expr), 'float'

    def node_mix(self, node, socket):
        factor = self.value(socket_by_id(node.inputs, 'Factor_Float'), 'float')
        if node.clamp_factor:
            factor = 'clamp(%s, 0.0, 1.0)' % factor
        f = self.variable('float', factor)
        if node.data_type == 'FLOAT':
            a = self.value(socket_by_id(node.inputs, 'A_Float'), 'float')
            b = self.value(socket_by_id(node.inputs, 'B_Float'), 'float')
            expr = 'mix(%s, %s, %s)' % (a, b, f)
            if node.clamp_result:
                expr = 'clamp(%s, 0.0, 1.0)' % expr
            return self.variable('float', expr), 'float'
        if node.data_type != 'RGBA':
            raise Unsupported('the Mix node\'s %s type' % node.data_type.title())
        a = self.variable('color', self.value(socket_by_id(node.inputs, 'A_Color'), 'color'))
        b = self.variable('color', self.value(socket_by_id(node.inputs, 'B_Color'), 'color'))
        if node.blend_type == 'MIX':
            expr = 'mix(%s, %s, %s)' % (a, b, f)
        elif node.blend_type in BLENDS:
            blend = re.sub(r'\b[ab]\b', lambda m: a if m.group(0) == 'a' else b, BLENDS[node.blend_type])
            expr = 'vec4(mix(%s.rgb, %s, %s), %s.a)' % (a, blend, f, a)
        else:
            raise Unsupported('the Mix node\'s %s blend mode' % node.blend_type.title().replace('_', ' '))
        if node.clamp_result:
            expr = 'clamp(%s, 0.0, 1.0)' % expr
        return self.variable('color', expr), 'color'

    def node_map_range(self, node, socket):
        if node.data_type != 'FLOAT':
            raise Unsupported('the Map Range node\'s %s type' % node.data_type.title())

        def inp(name):
            socket = next(s for s in node.inputs if s.name == name and s.enabled)
            return self.variable('float', self.value(socket, 'float'))
        value, from_min, from_max = inp('Value'), inp('From Min'), inp('From Max')
        to_min, to_max = inp('To Min'), inp('To Max')
        mode = node.interpolation_type
        f = self.variable('float', '(%s != %s ? (%s - %s) / (%s - %s) : 0.0)'
                          % (from_max, from_min, value, from_min, from_max, from_min))
        if mode == 'STEPPED':
            steps = inp('Steps')
            f = self.variable('float', '(%s > 0.0 ? floor(%s * (%s + 1.0)) / %s : 0.0)' % (steps, f, steps, steps))
        elif mode == 'SMOOTHSTEP':
            f = self.variable('float', 'smoothstep(0.0, 1.0, %s)' % f)
        elif mode == 'SMOOTHERSTEP':
            x = self.variable('float', 'clamp(%s, 0.0, 1.0)' % f)
            f = self.variable('float', '%s * %s * %s * (%s * (%s * 6.0 - 15.0) + 10.0)' % (x, x, x, x, x))
        elif mode != 'LINEAR':
            raise Unsupported('the Map Range node\'s %s interpolation' % mode.title())
        expr = '%s + %s * (%s - %s)' % (to_min, f, to_max, to_min)
        if node.clamp and mode in ('LINEAR', 'STEPPED'):
            expr = 'clamp(%s, min(%s, %s), max(%s, %s))' % (expr, to_min, to_max, to_min, to_max)
        return self.variable('float', expr), 'float'

    def node_valtorgb(self, node, socket):
        ramp = node.color_ramp
        if ramp.color_mode != 'RGB' or ramp.interpolation not in ('LINEAR', 'CONSTANT', 'EASE'):
            raise Unsupported('the Color Ramp node\'s %s interpolation'
                              % (ramp.interpolation if ramp.color_mode == 'RGB' else ramp.color_mode).title())
        key = (node.name, 'ramp')
        if key not in self.outputs:
            fac = self.variable('float', self.value(node.inputs['Fac'], 'float'))
            elements = sorted(ramp.elements, key=lambda e: e.position)
            color = self.variable('color', vec4(elements[0].color))
            for previous, element in zip(elements, elements[1:]):
                p0, p1 = number(previous.position), number(element.position)
                if ramp.interpolation == 'CONSTANT' or previous.position == element.position:
                    t = '(%s >= %s ? 1.0 : 0.0)' % (fac, p1)
                else:
                    t = 'clamp((%s - %s) / (%s - %s), 0.0, 1.0)' % (fac, p0, p1, p0)
                    if ramp.interpolation == 'EASE':
                        t = 'smoothstep(0.0, 1.0, %s)' % t
                self.lines.append('%s = mix(%s, %s, %s);' % (color, color, vec4(element.color), t))
            self.outputs[key] = (color, 'color')
        color = self.outputs[key][0]
        if socket.name == 'Alpha':
            return color + '.a', 'float'
        return color, 'color'

    def node_separate_color(self, node, socket):
        if node.mode != 'RGB':
            raise Unsupported('the Separate Color node\'s %s mode' % node.mode)
        key = (node.name, 'color')
        if key not in self.outputs:
            self.outputs[key] = (self.variable('color', self.value(node.inputs[0], 'color')), 'color')
        channel = {'Red': 'r', 'Green': 'g', 'Blue': 'b', 'Alpha': 'a'}[socket.name]
        return self.outputs[key][0] + '.' + channel, 'float'

    def node_combine_color(self, node, socket):
        if node.mode != 'RGB':
            raise Unsupported('the Combine Color node\'s %s mode' % node.mode)
        channels = [self.value(node.inputs[name], 'float') for name in ('Red', 'Green', 'Blue', 'Alpha')]
        return self.variable('color', 'vec4(%s)' % ', '.join(channels)), 'color'

    def node_glare(self, node, socket):
        """A Glare node is drawn by its own steps (Program.glare()), and its outputs
        read their targets. As in Blender, the Image output is exactly the input
        plus the glare."""
        index, image = self.program.glare(node)
        glare = 'glare%d' % index
        if socket.name == 'Glare':
            return self.variable('color', 'vec4(%s.rgb, 1.0)' % self.sample(glare)), 'color'
        if socket.name == 'Highlights':
            return self.variable('color', 'vec4(%s.rgb, 1.0)' % self.sample(glare + '_hl')), 'color'
        source = self.variable('color', self.sample(image))
        return self.variable('color', 'vec4(%s.rgb + %s.rgb, %s.a)' % (source, self.sample(glare), source)), 'color'
