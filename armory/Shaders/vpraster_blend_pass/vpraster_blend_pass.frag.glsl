#version 450
// Blend pass of the Viewport renderer: puts the blended materials over the lit image.
// It runs after the lighting pass (RasterTransparency.composite).
// Input: `tex`, the blended materials' colour (premultiplied by alpha) and coverage.
// The shader only copies it; the pass's blend state computes
// colour + lit * (1 - coverage).

uniform sampler2D tex;

in vec2 texCoord;
out vec4 fragColor;

void main() {
	fragColor = textureLod(tex, texCoord, 0.0);
}
