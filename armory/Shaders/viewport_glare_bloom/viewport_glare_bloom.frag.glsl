#version 450
#include "viewport_glare.inc"

// Glare node, Bloom, last pass: writes the glare at the highlights' resolution
// (ViewportCompositor). As in Blender, the glare is the average of the highlights and
// every coarser level. viewport_glare_up has summed the levels from the coarsest up;
// this pass brings the sum up with the same 3 x 3 tent and adds the highlights.
// Then it applies the node's Saturation, Tint and Strength.

uniform sampler2D hl;
uniform sampler2D up;   // the levels, summed (unused with one level)
uniform vec4 glare1;    // strength, saturation, 1 / levels, levels (the highlights included)
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;

void main() {
	vec3 sum = textureLod(hl, texCoord, 0.0).rgb;
	float levels = glare1.w;
	if (levels > 1.5) sum += arm_glare_tent(up, texCoord);
	fragColor = vec4(arm_glare_finish(sum * glare1.z, glare1.x, glare1.y, glareTint.rgb), 1.0);
}
