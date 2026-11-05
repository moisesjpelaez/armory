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
"""
import re

GBUFFER_IMAGES = 5  # the material images (arm_gbuffer.glsl, RenderPathEevee.gbuffer)


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
    output = re.compile(r'^out vec4 (\w+);', re.M)
    match = output.search(src)
    if match is None:
        raise RuntimeError('MaterialX pixel output not found')
    declarations = ('vec4 %s;\n' % match.group(1) +
                    ''.join('layout(location = %d) out vec4 armGbuffer%d;\n' % (i, i) for i in range(GBUFFER_IMAGES)) +
                    'in vec4 vd_armClip;\n'
                    'in vec4 vd_armPrevClip;')
    src = src[:match.start()] + declarations + src[match.end():]
    end = src.rstrip().rfind('}')  # main() is the last function
    if not re.search(r'\nvoid main\(\)\s*\{', src) or end < 0:
        raise RuntimeError('MaterialX main() not found')
    write = ''.join('    armGbuffer%d = arm_gbuffer%d;\n' % (i, i) for i in range(GBUFFER_IMAGES - 1))
    write += ('    armGbuffer4 = vec4(vd_armClip.xy / vd_armClip.w - vd_armPrevClip.xy / vd_armPrevClip.w, '
              'arm_gbuffer4, 1.0);\n')
    return src[:end] + write + src[end:]


def blended_output(src: str, shading: str, defines: dict) -> str:
    """Render Method: Blended (arm_gbuffer_blended). `shading` is arm_shade() and
    what it needs (lighting.shading_library()), put before main(); uniforms the
    MaterialX shader already declares are left out of it. The colour is the lit
    surface, unpremultiplied: the pass blends it by the opacity in alpha."""
    output = re.compile(r'^out vec4 (\w+);', re.M)
    match = output.search(src)
    if match is None:
        raise RuntimeError('MaterialX pixel output not found')
    src = src[:match.start()] + 'vec4 %s;\nout vec4 fragColor;' % match.group(1) + src[match.end():]

    declared = {name for _, name in uniforms(src)}
    shading = '\n'.join(line for line in shading.split('\n')
                        if not (re.match(r'^uniform\s', line) and
                                any(name in declared for _, name in uniforms(line))))
    main = re.search(r'\nvoid main\(\)\s*\{', src)
    end = src.rstrip().rfind('}')  # main() is the last function
    if main is None or end < 0:
        raise RuntimeError('MaterialX main() not found')
    write = '    fragColor = vec4(arm_shade(arm_gbuffer0, arm_gbuffer1, arm_gbuffer2, arm_gbuffer3, arm_gbuffer4, arm_position), arm_opacity);\n'
    src = src[:main.start()] + '\n' + shading + '\n' + src[main.start():end] + write + src[end:]

    version = re.search(r'^#version[^\n]*\n', src, re.M)
    if version is None:
        raise RuntimeError('MaterialX #version not found')
    defines_text = ''.join('#define %s %s\n' % item for item in defines.items())
    return src[:version.end()] + defines_text + src[version.end():]


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name)."""
    return re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?\s*(?:=[^;]*)?;', src, re.M)
