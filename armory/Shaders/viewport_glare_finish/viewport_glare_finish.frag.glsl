#version 450
#include "viewport_glare.inc"

// Glare node: the glare of a type summed in passes (Streaks, Simple Star, Sun
// Beams), scaled, then the node's Saturation (HSV saturation, largest channel
// kept), Tint and Strength, as for Bloom (ViewportCompositor).

uniform sampler2D tex;
uniform vec4 glare1; // strength, saturation, scale
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;

void main() {
	fragColor = vec4(arm_glare_finish(textureLod(tex, texCoord, 0.0).rgb * glare1.z, glare1.x, glare1.y, glareTint.rgb), 1.0);
}
