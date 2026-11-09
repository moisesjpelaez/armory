"""Text fixes applied to MaterialX's generated GLSL (the material pass) before
Krafix sees it.

flatten_varyings: MaterialX passes vertex data in an interface block
    (`in VertexData { ... } vd;`). Krafix turns the vertex-stage block into a
    separate output parameter, which puts SV_Position first in the D3D11
    output signature while the pixel stage expects the block members first.
    D3D11 links stages by register, so every varying arrived shifted by one
    (the tangent received the normal). Plain varyings keep both stages in the
    same order.

gbuffer_output: the material pass writes the material images, not a colour.

blended_output: a blended material lights its values itself (arm_shade(), the
    lighting pass's shading) and writes the colour with its opacity.

aov_output: an AOV output's pass writes the AOV's value.
"""
import re

GBUFFER_IMAGES = 5  # the material images (arm_gbuffer.glsl, RenderPathViewportRaster.gbuffer)
MOTION_INPUTS = 'in vec4 vd_armClip;\nin vec4 vd_armPrevClip;'  # the clip positions vertex.py passes in


def replace_output(src: str, declarations: str) -> str:
    """MaterialX's pixel output (`out vec4 <name>;`) becomes a plain variable the
    generated code still writes, followed by `declarations`: the pass's own outputs."""
    match = re.search(r'^out vec4 (\w+);', src, re.M)
    if match is None:
        raise RuntimeError('MaterialX pixel output not found')
    return src[:match.start()] + 'vec4 %s;\n' % match.group(1) + declarations + src[match.end():]


def main_end(src: str) -> int:
    """Where main()'s closing brace is: main() is the last function."""
    end = src.rstrip().rfind('}')
    if not re.search(r'\nvoid main\(\)\s*\{', src) or end < 0:
        raise RuntimeError('MaterialX main() not found')
    return end


def append_to_main(src: str, code: str) -> str:
    end = main_end(src)
    return src[:end] + code + src[end:]


def flatten_varyings(src: str) -> str:
    block = re.compile(r'\b(in|out)\s+VertexData\s*\{([^}]*)\}\s*vd\s*;', re.S)
    match = block.search(src)
    if match is None:
        return src
    qualifier, members = match.group(1), match.group(2)
    lines = []
    for decl in members.split(';'):
        decl = decl.strip()
        if decl:
            kind, name = decl.split()
            lines.append('%s %s vd_%s;' % (qualifier, kind, name))
    src = src[:match.start()] + '\n'.join(lines) + src[match.end():]
    return re.sub(r'\bvd\.([A-Za-z_][A-Za-z0-9_]*)', r'vd_\1', src)


def gbuffer_output(src: str) -> str:
    """Material pass (arm_gbuffer): writes the material images instead of a colour.
    The last image also holds the pixel's screen motion for temporal anti-aliasing
    (current minus previous NDC position, from the unjittered clip positions the
    vertex stage passes in, vertex.py)."""
    src = replace_output(src, ''.join('layout(location = %d) out vec4 armGbuffer%d;\n' % (i, i)
                                      for i in range(GBUFFER_IMAGES)) + MOTION_INPUTS)
    write = ''.join('    armGbuffer%d = arm_gbuffer%d;\n' % (i, i) for i in range(GBUFFER_IMAGES - 1))
    write += '    armGbuffer4 = vec4(arm_motion(vd_armClip, vd_armPrevClip), arm_gbuffer4, 1.0);\n'
    return append_to_main(src, write)


def blended_output(src: str, shading: str, defines: dict) -> str:
    """Render Method: Blended (arm_gbuffer_blended). `shading` is arm_shade() and
    what it needs (lighting.shading_library()), put before main(); uniforms the
    MaterialX shader already declares are left out of it. The colour is the lit
    surface, unpremultiplied: the pass blends it by the opacity in alpha. The
    second output is the screen motion, which only the opaque pass (Blended
    without alpha) has an image for."""
    src = replace_output(src, 'layout(location = 0) out vec4 fragColor;\n'
                              'layout(location = 1) out vec4 armMotion;\n' + MOTION_INPUTS)

    declared = {name for _, name in uniforms(src)}
    shading = '\n'.join(line for line in shading.split('\n')
                        if not (re.match(r'^uniform\s', line) and
                                any(name in declared for _, name in uniforms(line))))
    end = main_end(src)
    main = re.search(r'\nvoid main\(\)\s*\{', src)
    write = ('    fragColor = vec4(arm_shade(arm_gbuffer0, arm_gbuffer1, arm_gbuffer2, arm_gbuffer3, arm_gbuffer4, arm_position), arm_opacity);\n'
             '    armMotion = vec4(arm_motion(vd_armClip, vd_armPrevClip), 0.0, 1.0);\n')
    src = src[:main.start()] + '\n' + shading + '\n' + src[main.start():end] + write + src[end:]

    version = re.search(r'^#version[^\n]*\n', src, re.M)
    if version is None:
        raise RuntimeError('MaterialX #version not found')
    defines_text = ''.join('#define %s %s\n' % item for item in defines.items())
    return src[:version.end()] + defines_text + src[version.end():]


def aov_output(src: str, kind: str) -> str:
    """An AOV output's pass (mx_export.aov_material()): the AOV's input is the
    document's emission. Written as Eevee's AOV passes hold it (measured): a
    colour with alpha 1, a value in red; 0 where nothing writes the AOV."""
    src = replace_output(src, 'out vec4 fragColor;')
    value = 'arm_gbuffer3.rgb' if kind == 'COLOR' else 'arm_gbuffer3.r, 0.0, 0.0'
    return append_to_main(src, '    fragColor = vec4(%s, 1.0);\n' % value)


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name), leaving out those of #ifdef blocks the source
    compiles out (active_source())."""
    return re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?\s*(?:=[^;]*)?;', active_source(src), re.M)


def active_source(src: str) -> str:
    """`src` without the lines of #ifdef / #ifndef blocks on the renderer's own switches
    (ARM_..., set by #define lines in the source itself, e.g. lighting.py's versions)
    that are compiled out. Blocks on any other name (compiled.inc's _InvY...) keep
    both branches: their uniforms are bound either way."""
    defined = set()
    stack = []  # per open block: True / False (its branch is compiled in or out), None (both kept)
    lines = []
    for line in src.split('\n'):
        words = line.split()
        directive = words[0] if words else ''
        if directive in ('#ifdef', '#ifndef') and len(words) > 1:
            name = words[1]
            stack.append(None if not name.startswith('ARM_') else (name in defined) == (directive == '#ifdef'))
            continue
        if directive == '#if':  # an expression: both branches kept
            stack.append(None)
            continue
        if directive == '#elif' and stack:
            stack[-1] = None
            continue
        if directive == '#else' and stack:
            stack[-1] = None if stack[-1] is None else not stack[-1]
            continue
        if directive == '#endif' and stack:
            stack.pop()
            continue
        if False in stack:
            continue
        if directive == '#define' and len(words) > 1:
            defined.add(words[1])
        lines.append(line)
    return '\n'.join(lines)
