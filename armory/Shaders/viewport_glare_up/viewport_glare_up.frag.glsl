#version 450
#include "viewport_glare.inc"

// Glare node, Bloom: one step up from the coarsest level (ViewportCompositor). As in
// Blender, it brings the already summed coarser levels up to this level's resolution
// with a 3 x 3 tent (arm_glare_tent), and adds this level.

uniform sampler2D tex;   // the coarser levels, summed
uniform sampler2D level; // this level

in vec2 texCoord;
out vec4 fragColor;


void main() {
	fragColor = vec4(arm_glare_tent(tex, texCoord) + textureLod(level, texCoord, 0.0).rgb, 1.0);
}
