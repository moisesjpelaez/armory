#version 450
// Glare node, Simple Star: one pass along one line of the star (ViewportCompositor).
// As in Blender, each line repeats one blur kernel, in iterations - 1 passes, at steps
// of 1, 2, 3... pixels. The kernel weighs q a^|k| at distance k, where a = fade / 2,
// and q - (1 - fade) at the centre; the weights sum to 1. It is cut at 12 taps a side,
// where a^12 < 0.0003. The star is the sum of its two lines; the last pass of each
// line adds to the sum (viewport_glare_star_add). Outside the image counts as black.

#include "compiled.inc"
#include "viewport_glare.inc"

uniform sampler2D tex;
uniform vec4 glare2; // xy: step between taps in pixels (Blender's image axes, y up), z: a, w: q
uniform vec4 glare3; // x: the centre weight

in vec2 texCoord;
out vec4 fragColor;

const int TAPS = 12;


void main() {
	vec2 step = glare2.xy / vec2(textureSize(tex, 0));
	#ifdef _InvY
	step.y = -step.y; // texture rows run downwards
	#endif
	float a = glare2.z;
	float centre = glare3.x;
	vec3 sum = centre * arm_glare_tap(tex, texCoord);
	float total = centre;
	float w = glare2.w;
	for (int k = 1; k <= TAPS; k++) {
		w *= a;
		sum += w * (arm_glare_tap(tex, texCoord + float(k) * step) + arm_glare_tap(tex, texCoord - float(k) * step));
		total += 2.0 * w;
	}
	fragColor = vec4(sum / total, 1.0);
}
