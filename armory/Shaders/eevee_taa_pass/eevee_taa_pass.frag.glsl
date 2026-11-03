#version 450

#include "compiled.inc"

uniform sampler2D tex;      // this frame (jittered), linear HDR
uniform sampler2D history;  // last resolved frame
uniform sampler2D velocity; // NDC motion: current minus previous position
uniform vec4 taa;           // x: weight of this frame (1 = no history), yz: jitter in pixels (NDC axes), w: filter size in pixels
uniform vec2 screenSizeInv;

in vec2 texCoord;
out vec4 fragColor;

// Temporal anti-aliasing for Eevee's taa_samples / filter_size:
// - this frame is reconstructed with Blender's pixel filter (a Blackman-Harris,
//   approximated by a Gaussian over filter_size) around the jittered samples,
// - last frame is reprojected with the velocity buffer and clipped to the
//   neighbourhood's colour range (YCoCg variance box) to limit ghosting,
// - both are blended with weights reduced for bright pixels, against flicker.

vec3 toYCoCg(vec3 c) {
	return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c) {
	return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

float peak(vec3 c) {
	return max(c.r, max(c.g, c.b));
}

void main() {
	vec2 jitter = taa.yz;
	#ifdef _InvY
	jitter.y = -jitter.y; // texture rows run downwards
	#endif
	float filterScale = 1.5 / max(taa.w, 0.01);

	vec3 current = vec3(0.0);
	float currentWeight = 0.0;
	vec3 m1 = vec3(0.0);
	vec3 m2 = vec3(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 offset = vec2(float(x), float(y));
			vec3 c = max(textureLod(tex, texCoord + offset * screenSizeInv, 0.0).rgb, vec3(0.0));
			vec3 ycocg = toYCoCg(c);
			m1 += ycocg;
			m2 += ycocg * ycocg;
			// Distance from this pixel's centre to where the neighbour's sample was taken
			vec2 d = (offset + jitter) * filterScale;
			float w = exp(-2.29 * dot(d, d)) / (1.0 + peak(c));
			current += c * w;
			currentWeight += w;
		}
	}
	current /= currentWeight;
	float alpha = textureLod(tex, texCoord, 0.0).a;

	vec2 motion = textureLod(velocity, texCoord, 0.0).xy * 0.5;
	#ifdef _InvY
	motion.y = -motion.y;
	#endif
	vec2 previousUv = texCoord - motion;
	if (taa.x >= 1.0 || any(lessThan(previousUv, vec2(0.0))) || any(greaterThan(previousUv, vec2(1.0)))) {
		fragColor = vec4(current, alpha);
		return;
	}

	vec3 mean = m1 / 9.0;
	vec3 deviation = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
	vec3 history = max(textureLod(history, previousUv, 0.0).rgb, vec3(0.0));
	history = fromYCoCg(clamp(toYCoCg(history), mean - 1.25 * deviation, mean + 1.25 * deviation));

	float wc = taa.x / (1.0 + peak(current));
	float wh = (1.0 - taa.x) / (1.0 + peak(history));
	fragColor = vec4((current * wc + history * wh) / (wc + wh), alpha);
}
