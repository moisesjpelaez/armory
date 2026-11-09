#version 450

#include "compiled.inc"
#include "viewport_glare.inc"

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


void main() {
	vec2 step = glare2.xy / vec2(textureSize(tex, 0));
	#ifdef _InvY
	step.y = -step.y; // texture rows run downwards
	#endif
	float fade = glare2.z;
	float m = 1.0 - glare3.x; // 1 - colour modulation
	vec3 sum = arm_glare_tap(tex, texCoord);
	sum += fade * vec3(1.0, m, m) * arm_glare_tap(tex, texCoord + step);
	sum += fade * fade * vec3(m, m, 1.0) * arm_glare_tap(tex, texCoord + 2.0 * step);
	sum += fade * fade * fade * vec3(m, 1.0, m) * arm_glare_tap(tex, texCoord + 3.0 * step);
	fragColor = vec4(sum, 1.0);
}
