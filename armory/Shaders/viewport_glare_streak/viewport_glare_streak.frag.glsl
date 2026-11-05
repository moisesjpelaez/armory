#version 450

#include "compiled.inc"

// Glare node, Streaks: one pass of one streak (ViewportCompositor). As measured in
// Blender 5.2, a streak sums the highlights at distances k = 0 .. 4^iterations - 1
// along its direction, weighted fade^k, by passes of four taps at steps of 1, 4,
// 16... pixels; with Color Modulation, taps 1, 2 and 3 of a pass are tinted red,
// blue and green by cm^(pass + 1). Outside the image counts as black.

uniform sampler2D tex;
uniform vec4 glare2; // step between taps in pixels (Blender's image axes, y up), fade^step
uniform vec4 glare3; // colour modulation of this pass

in vec2 texCoord;
out vec4 fragColor;

vec3 tap(vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec3(0.0);
	return textureLod(tex, uv, 0.0).rgb;
}

void main() {
	vec2 step = glare2.xy / vec2(textureSize(tex, 0));
	#ifdef _InvY
	step.y = -step.y; // texture rows run downwards
	#endif
	float m = 1.0 - glare3.x;
	vec3 sum = tap(texCoord);
	sum += glare2.z * vec3(1.0, m, m) * tap(texCoord + step);
	sum += glare2.z * glare2.z * vec3(m, m, 1.0) * tap(texCoord + 2.0 * step);
	sum += glare2.z * glare2.z * glare2.z * vec3(m, 1.0, m) * tap(texCoord + 3.0 * step);
	fragColor = vec4(sum, 1.0);
}
