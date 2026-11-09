#version 450
#include "viewport_glare.inc"

// Glare node, Bloom: the glare, at the highlights' resolution (ViewportCompositor).
// As measured in Blender 5.2: the highlights plus every level, summed from the
// coarsest up (Shaders/viewport_glare_up) and brought up here with the same 3 x 3
// tent, averaged. Then the node's Saturation (HSV saturation, largest channel
// kept), Tint and Strength.

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
