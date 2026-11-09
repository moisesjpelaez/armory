#version 450
// Glare node, last pass of Streaks and Simple Star (ViewportCompositor): scales the
// glare their passes summed, then applies the node's Saturation, Tint and Strength,
// as Bloom does.

#include "viewport_glare.inc"

uniform sampler2D tex;
uniform vec4 glare1; // strength, saturation, scale
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;

void main() {
	fragColor = vec4(arm_glare_finish(textureLod(tex, texCoord, 0.0).rgb * glare1.z, glare1.x, glare1.y, glareTint.rgb), 1.0);
}
