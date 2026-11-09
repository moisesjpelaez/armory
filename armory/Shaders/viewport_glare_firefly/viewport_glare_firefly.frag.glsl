#version 450

// Glare node, Bloom: makes the first level, at half the highlights' resolution
// (ViewportCompositor). It filters as Blender does, with less weight on very bright
// spots, so that a lone bright pixel (a firefly) spreads less than a bright area:
// - At each texel corner near this pixel, average the four 2 x 2 averages around it
//   (bilinear reads one texel away). Each counts with weight 1 / (1 + 0.5 max(m - 1, 0)),
//   where m is its largest channel.
// - This pixel is the average of the 3 x 3 corners around its centre, weighted
//   1/4, 1/2, 1/4 per axis.
// Edges are extended (clamped addressing).

uniform sampler2D tex; // highlights

in vec2 texCoord;
out vec4 fragColor;

void main() {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 texel = 1.0 / size;
	vec2 centre = texCoord * size; // a texel corner of the highlights
	// The 2 x 2 averages around the centre (5 x 5 positions one texel apart) and their weights
	vec3 taps[25];
	float weights[25];
	for (int j = 0; j < 5; j++) {
		for (int i = 0; i < 5; i++) {
			vec3 t = textureLod(tex, (centre + vec2(float(i - 2), float(j - 2))) * texel, 0.0).rgb;
			taps[j * 5 + i] = t;
			weights[j * 5 + i] = 1.0 / (1.0 + 0.5 * max(max(t.r, max(t.g, t.b)) - 1.0, 0.0));
		}
	}
	vec3 sum = vec3(0.0);
	for (int j = 0; j < 3; j++) {
		for (int i = 0; i < 3; i++) {
			// Corner (i - 1, j - 1) from the centre: its taps at (+-1, +-1)
			vec3 corner = vec3(0.0);
			float total = 0.0;
			for (int b = 0; b < 2; b++) {
				for (int a = 0; a < 2; a++) {
					int k = (j + 2 * b) * 5 + (i + 2 * a);
					corner += weights[k] * taps[k];
					total += weights[k];
				}
			}
			sum += (i == 1 ? 0.5 : 0.25) * (j == 1 ? 0.5 : 0.25) * corner / total;
		}
	}
	fragColor = vec4(sum, 1.0);
}
