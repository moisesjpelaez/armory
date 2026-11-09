"""Preprocessing and reading the GLSL of the Viewport renderer's shaders.

The renderer's own switches are #ifdef / #ifndef blocks on names that start with
ARM_. They are evaluated here, before the shader compiler sees the code:
  - resolve() applies them to a template file, with the switches the caller sets.
  - active_source() applies them to an assembled shader, whose own #define lines
    set them (for example lighting.py's versions).
Blocks on any other name (such as compiled.inc's _InvY) are left to the shader
compiler, so both of their branches are kept.

inputs() and uniforms() read the declarations from the code that gets compiled,
so the shader data always matches the shader.
"""
import os
import re


class Switches:
    """The #if blocks open at the current line, while a shader is read line by
    line. A block on an ARM_ name is compiled in or out by whether the name is in
    `defined`. A block on any other name keeps both branches."""
    SWITCH = 'switch'  # a line of an ARM_ block (#ifdef, #ifndef, #else, #endif): never in the output
    BLOCK = 'block'    # a line of another block: left to the shader compiler

    def __init__(self, defined: set):
        self.defined = defined
        self.stack = []  # per open block: True / False (its branch is compiled in or out), None (both kept)

    def read(self, words: list) -> str:
        """Takes the line's directive into account (`words` is the line split on
        whitespace). Returns SWITCH, BLOCK, or None for a line that opens or closes
        no block."""
        directive = words[0] if words else ''
        if directive in ('#ifdef', '#ifndef') and len(words) > 1:
            name = words[1]
            if name.startswith('ARM_'):
                self.stack.append((name in self.defined) == (directive == '#ifdef'))
                return self.SWITCH
            self.stack.append(None)
            return self.BLOCK
        if directive == '#if':  # an expression: both branches kept
            self.stack.append(None)
            return self.BLOCK
        if not self.stack or directive not in ('#elif', '#else', '#endif'):
            return None
        top = self.stack[-1]
        if directive == '#elif':
            if top is not None:
                raise RuntimeError('Viewport renderer: #elif in an #ifdef block on an ARM_ name is not supported')
            return self.BLOCK
        if directive == '#else':
            if top is None:
                return self.BLOCK
            self.stack[-1] = not top
            return self.SWITCH
        self.stack.pop()
        return self.BLOCK if top is None else self.SWITCH

    def compiled_in(self) -> bool:
        """Whether the current line is compiled in."""
        return False not in self.stack


def resolve(template: str, flags: set, defines: dict = None) -> str:
    """The shader template at path `template`, with the renderer's options applied:
      - its #include "..." lines (files next to it) are inlined
      - #ifdef / #ifndef / #else / #endif on ARM_ names are evaluated against `flags`
      - `defines` (name -> value) are written after #version
    Other directives are left to the shader compiler. The result is exactly what
    gets compiled, so its inputs and uniforms can be read from it."""
    with open(template, encoding='utf-8') as f:
        lines = f.read().split('\n')
    out = []
    switches = Switches(flags)
    for line in lines:
        words = line.split()
        if switches.read(words) == Switches.SWITCH or not switches.compiled_in():
            continue
        directive = words[0] if words else ''
        if directive == '#include':
            out.append(resolve(os.path.join(os.path.dirname(template), words[1].strip('"')), flags))
            continue
        out.append(line)
        if directive == '#version' and defines:
            out += ['#define %s %s' % item for item in defines.items()]
    if switches.stack:
        raise RuntimeError('Viewport renderer: unterminated #if in %s' % os.path.basename(template))
    return '\n'.join(out)


def active_source(src: str) -> str:
    """`src` without the lines that the renderer's switches compile out, and
    without the lines that open or close a block. The switches are set by the
    #define lines of `src` itself."""
    switches = Switches(set())
    lines = []
    for line in src.split('\n'):
        words = line.split()
        if switches.read(words) is not None or not switches.compiled_in():
            continue
        if words and words[0] == '#define' and len(words) > 1:
            switches.defined.add(words[1])
        lines.append(line)
    return '\n'.join(lines)


def inputs(src: str) -> list:
    """Global `in` declarations as (type, name), in declaration order."""
    return re.findall(r'^in\s+(\w+)\s+(\w+)\s*;', src, re.M)


def uniforms(src: str) -> list:
    """Global uniforms as (type, name). Uniforms inside blocks that the renderer's
    switches compile out are left out (active_source())."""
    return re.findall(r'^uniform\s+(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?\s*(?:=[^;]*)?;', active_source(src), re.M)
