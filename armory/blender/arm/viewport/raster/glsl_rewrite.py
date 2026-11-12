"""Text changes made to the GLSL that MaterialX generates for the material pass,
before Krafix compiles it.

flatten_varyings: MaterialX passes vertex data in an interface block
    (`in VertexData { ... } vd;`). Krafix turns the vertex stage's block into a
    separate output parameter. That puts SV_Position first in the D3D11 output
    signature, while the pixel stage expects the block members first. D3D11
    links the stages by register, so every varying would arrive shifted by one
    (the tangent would get the normal). Plain varyings keep both stages in the
    same order.

gbuffer_output: the material pass writes the material images, not a colour.

blended_output: a blended material lights its surface itself, with the lighting
    pass's shading (arm_shade()), and writes the colour with its opacity.

aov_output: an AOV output's pass writes the AOV's value.
"""
import re

import arm
import arm.viewport.glsl as glsl

if arm.is_reload(__name__):
    glsl = arm.reload_module(glsl)
else:
    arm.enable_reload(__name__)

GBUFFER_IMAGES = 5  # fixed: the five images are laid out in arm_gbuffer.glsl, gbuffer_output() and RenderPathViewportRaster.gbuffer
MOTION_INPUTS = 'in vec4 vd_armClip;\nin vec4 vd_armPrevClip;'  # the clip positions vertex.py passes in


def replace_output(src: str, declarations: str) -> str:
    """Turns MaterialX's pixel output (`out vec4 <name>;`) into a plain variable,
    which the generated code still writes, and adds `declarations` after it: the
    pass's own outputs."""
    match = re.search(r'^out vec4 (\w+);', src, re.M)
    if match is None:
        raise RuntimeError('MaterialX pixel output not found')
    return src[:match.start()] + 'vec4 %s;\n' % match.group(1) + declarations + src[match.end():]


def main_end(src: str) -> int:
    """The position of main()'s closing brace. MaterialX writes main() last."""
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
            glsl_type, name = decl.split()
            lines.append('%s %s vd_%s;' % (qualifier, glsl_type, name))
    src = src[:match.start()] + '\n'.join(lines) + src[match.end():]
    return re.sub(r'\bvd\.([A-Za-z_][A-Za-z0-9_]*)', r'vd_\1', src)


def gbuffer_output(src: str) -> str:
    """Material pass (arm_gbuffer): writes the material images instead of a colour.
    The last image also holds the pixel's screen motion for temporal anti-aliasing.
    The motion is the current minus the previous NDC position, computed from the
    unjittered clip positions that the vertex stage passes in (vertex.py)."""
    src = replace_output(src, ''.join('layout(location = %d) out vec4 armGbuffer%d;\n' % (i, i)
                                      for i in range(GBUFFER_IMAGES)) + MOTION_INPUTS)
    write = ''.join('    armGbuffer%d = arm_gbuffer%d;\n' % (i, i) for i in range(GBUFFER_IMAGES - 1))
    write += '    armGbuffer4 = vec4(arm_motion(vd_armClip, vd_armPrevClip), arm_gbuffer4, 1.0);\n'
    return append_to_main(src, write)


def blended_output(src: str, shading: str, defines: dict) -> str:
    """Render Method: Blended (arm_gbuffer_blended). `shading` is arm_shade() and
    the code it needs (lighting.shading_library()). It is put before main(),
    without the uniforms the MaterialX shader already declares. The colour output
    is the lit surface, not premultiplied, with the opacity in alpha for the
    pass's blending. The second output is the screen motion. The blended passes
    draw into one image only (RasterTransparency.TARGET), so it is not stored."""
    src = replace_output(src, 'layout(location = 0) out vec4 fragColor;\n'
                              'layout(location = 1) out vec4 armMotion;\n' + MOTION_INPUTS)

    declared = {name for _, name in glsl.uniforms(src)}
    shading = '\n'.join(line for line in shading.split('\n')
                        if not (re.match(r'^uniform\s', line) and
                                any(name in declared for _, name in glsl.uniforms(line))))
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


def aov_output(src: str, aov_type: str) -> str:
    """An AOV output's pass (mx_aov.aov_material()). The AOV's input is the
    document's emission. It is written the way Eevee's AOV passes hold it: a
    colour with alpha 1, or a value in red. Where nothing writes the AOV, the
    image stays 0."""
    src = replace_output(src, 'out vec4 fragColor;')
    value = 'arm_gbuffer3.rgb' if aov_type == 'COLOR' else 'arm_gbuffer3.r, 0.0, 0.0'
    return append_to_main(src, '    fragColor = vec4(%s, 1.0);\n' % value)
