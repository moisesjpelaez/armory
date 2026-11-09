#version 450
#include "viewport_glare.inc"

// Glare node, Bloom: one step up (ViewportCompositor). As measured in Blender 5.2:
// the coarser levels, already summed, brought up with a 3 x 3 tent of bilinear
// taps half a coarse texel apart (weights 1, 2, 1 per axis), plus this level.

uniform sampler2D tex;   // the coarser levels, summed
uniform sampler2D level; // this level

in vec2 texCoord;
out vec4 fragColor;


void main() {
	fragColor = vec4(arm_glare_tent(tex, texCoord) + textureLod(level, texCoord, 0.0).rgb, 1.0);
}
