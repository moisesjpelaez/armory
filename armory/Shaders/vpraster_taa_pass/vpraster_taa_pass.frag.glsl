#version 450
// Temporal anti-aliasing (TAA) of the Viewport renderer, for Eevee's taa_samples and
// filter_size. It runs after the compositor and before the film pass. The camera is
// jittered a little every frame (RasterTaa), and this pass averages the frames:
// - This frame is filtered around the jittered samples with a Gaussian close to
//   Blender's pixel filter (Blackman-Harris). RasterTaa precomputes the 3 x 3 filter
//   weights once per frame (taaWeights).
// - Last frame's result (the history) is moved by the screen motion and clamped to
//   the colour range of this pixel's neighbourhood (a YCoCg variance box), which
//   limits ghosting.
// - Both are blended. Here and in the filter, bright samples get smaller weights
//   (Karis 2014), against flicker.
// Output: the resolved image, which is also next frame's history.

#include "compiled.inc"

uniform sampler2D tex;      // this frame (jittered), linear HDR
uniform sampler2D history;  // last resolved frame
uniform sampler2D velocity; // NDC motion: current minus previous position
// x: weight of this frame (1 = no history). The shader reads only x; yzw (jitter and
// filter size) are already in taaWeights.
uniform vec4 taa;
// The pixel filter's weight of each 3 x 3 tap (RasterTaa.weights), one vec4 per row
// in NDC's y order, taps in xyz. vec4s, because Direct3D pads each element of a float
// array to 16 bytes.
uniform vec4 taaWeights[3];
uniform vec2 screenSizeInv;

in vec2 texCoord;
out vec4 fragColor;

vec3 toYCoCg(vec3 c) {
	return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c) {
	return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Brightness as the largest channel
float peak(vec3 c) {
	return max(c.r, max(c.g, c.b));
}

void main() {
	vec3 current = vec3(0.0);
	float currentWeight = 0.0;
	vec4 centre = vec4(0.0);
	vec3 m1 = vec3(0.0);
	vec3 m2 = vec3(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec4 s = textureLod(tex, texCoord + vec2(float(x), float(y)) * screenSizeInv, 0.0);
			if (x == 0 && y == 0) centre = s;
			vec3 c = max(s.rgb, vec3(0.0));
			vec3 ycocg = toYCoCg(c);
			m1 += ycocg;
			m2 += ycocg * ycocg;
			// The filter's weight at the neighbour's sample. Where texture rows run
			// downwards, the rows are read mirrored.
			#ifdef _InvY
			float w = taaWeights[1 - y][x + 1];
			#else
			float w = taaWeights[y + 1][x + 1];
			#endif
			w /= 1.0 + peak(c);
			current += c * w;
			currentWeight += w;
		}
	}
	// A Filter Size near 0 makes every weight 0. The centre sample is then used: the
	// jitter stays within half a pixel, so it is the nearest sample, which is what a
	// vanishing filter keeps.
	current = currentWeight > 0.0 ? current / currentWeight : max(centre.rgb, vec3(0.0));
	float alpha = centre.a;

	vec2 motion = textureLod(velocity, texCoord, 0.0).xy * 0.5;
	#ifdef _InvY
	motion.y = -motion.y;
	#endif
	vec2 previousUv = texCoord - motion;
	// Written as "inside" so that a NaN position, whose comparisons are all false, also
	// gets no history
	bool inside = all(greaterThanEqual(previousUv, vec2(0.0))) && all(lessThanEqual(previousUv, vec2(1.0)));
	if (taa.x >= 1.0 || !inside) {
		fragColor = vec4(current, alpha);
		return;
	}

	// Clamp the history to the neighbourhood's mean +- 1.25 standard deviations in
	// YCoCg. A smaller box leaves less ghosting behind moving edges; a larger one
	// flickers less
	vec3 mean = m1 / 9.0;
	vec3 deviation = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
	vec3 history = max(textureLod(history, previousUv, 0.0).rgb, vec3(0.0));
	history = fromYCoCg(clamp(toYCoCg(history), mean - 1.25 * deviation, mean + 1.25 * deviation));

	// Blend weights divided by 1 + brightness, so one bright frame does not dominate
	float wc = taa.x / (1.0 + peak(current));
	float wh = (1.0 - taa.x) / (1.0 + peak(history));
	fragColor = vec4((current * wc + history * wh) / (wc + wh), alpha);
}
