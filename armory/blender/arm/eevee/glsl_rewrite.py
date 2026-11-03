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


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name)."""
    return re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?\s*(?:=[^;]*)?;', src, re.M)
