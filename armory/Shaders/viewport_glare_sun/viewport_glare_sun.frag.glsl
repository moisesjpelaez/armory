#version 450

#include "compiled.inc"
#include "viewport_glare.inc"

// Glare node, Sun Beams (ViewportCompositor). As measured in Blender 5.2: each pixel
// averages the highlights on the way towards the sun, over U = min(size x the
// image diagonal, the distance to the sun), one sample per pixel of U, weighted
// (1 - u / U)^2. Long rays are sampled at most MAX_SAMPLES times, jittered per
// pixel and frame (temporal anti-aliasing averages them). Outside the image
// counts as black. Then the node's Saturation, Tint and Strength, as for Bloom: the
// glare target is written here, without a pass of its own for them.

uniform sampler2D tex;
uniform vec4 glare1; // strength, saturation, scale
uniform vec4 glare2; // sun position (fraction of the image, y up), size x diagonal in pixels, frame
uniform vec4 glare3; // samples at most
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;


float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 sun = glare2.xy;
	float maxLength = glare2.z; // Size x the image diagonal, in pixels
	float frame = glare2.w;
	float maxSamples = glare3.x;
	#ifdef _InvY
	sun.y = 1.0 - sun.y; // texture rows run downwards
	#endif
	vec2 towards = (sun - texCoord) * size; // in pixels
	float distance = length(towards);
	float U = min(maxLength, distance);
	float n = max(ceil(U), 1.0);
	float jitter = 0.0;
	if (n > maxSamples) {
		n = maxSamples;
		jitter = hash(gl_FragCoord.xy + frame * 17.0);
	}
	vec2 stepUv = distance > 0.0 ? (towards / distance) * (U / n) / size : vec2(0.0);
	vec3 sum = vec3(0.0);
	float total = 0.0;
	for (int j = 0; j < int(n); j++) {
		float f = (float(j) + jitter) / n;
		float w = (1.0 - f) * (1.0 - f);
		sum += w * arm_glare_tap(tex, texCoord + stepUv * (float(j) + jitter));
		total += w;
	}
	fragColor = vec4(arm_glare_finish(sum / max(total, 1e-6) * glare1.z, glare1.x, glare1.y, glareTint.rgb), 1.0);
}
