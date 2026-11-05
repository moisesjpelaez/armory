#version 450

// Blended materials over the lit image (EeveeTransparency.composite): `tex` holds
// their colour, premultiplied, and their coverage; the pass's blending computes
// colour + lit * (1 - coverage).

uniform sampler2D tex;

in vec2 texCoord;
out vec4 fragColor;

void main() {
	fragColor = textureLod(tex, texCoord, 0.0);
}
