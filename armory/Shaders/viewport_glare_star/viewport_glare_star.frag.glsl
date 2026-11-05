#version 450

#include "compiled.inc"

// Glare node, Simple Star: one pass along one line of the star (ViewportCompositor).
// As measured in Blender 5.2, each line repeats one kernel at steps of 1, 2,
// 3... pixels (iterations - 1 passes): q a^|k| at distance k, a = fade / 2, and
// q - (1 - fade) at the centre, summing to 1 (cut here at 12 taps a side, where
// a^12 < 0.0003). The star is the sum of its two lines. Outside the image counts
// as black.

uniform sampler2D tex;
uniform vec4 glare2; // step between taps in pixels (Blender's image axes, y up), a, q
uniform vec4 glare3; // the centre weight

in vec2 texCoord;
out vec4 fragColor;

const int TAPS = 12;

vec3 tap(vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec3(0.0);
	return textureLod(tex, uv, 0.0).rgb;
}

void main() {
	vec2 step = glare2.xy / vec2(textureSize(tex, 0));
	#ifdef _InvY
	step.y = -step.y; // texture rows run downwards
	#endif
	float a = glare2.z;
	float centre = glare3.x;
	vec3 sum = centre * tap(texCoord);
	float total = centre;
	float w = glare2.w;
	for (int k = 1; k <= TAPS; k++) {
		w *= a;
		sum += w * (tap(texCoord + float(k) * step) + tap(texCoord - float(k) * step));
		total += 2.0 * w;
	}
	fragColor = vec4(sum / total, 1.0);
}
