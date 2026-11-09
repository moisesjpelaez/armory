#version 450

// Glare node, first pass (ViewportCompositor): extracts the highlights of the node's
// input image, at the node's Quality. Every glare type starts from these highlights.
// As in Blender:
// - Quality Medium and Low first average the 2 x 2 or 4 x 4 input pixels under this
//   pixel.
// - A pixel's brightness is its largest channel m. Its highlight keeps its colour,
//   scaled by f(m) / m, where f(m) = m - threshold, softened by a quadratic knee of
//   half-width `smoothness`.
// - Clamp caps f(m) at the maximum, with the same knee.

uniform sampler2D tex;
uniform vec4 glare0; // threshold, smoothness, maximum (negative: no clamp), quality factor (1, 2, 4)

in vec2 texCoord;
out vec4 fragColor;

float knee(float x, float s) {
	// max(x, 0), rounded over (-s, s)
	if (s > 0.0 && abs(x) < s) return (x + s) * (x + s) / (4.0 * s);
	return max(x, 0.0);
}

void main() {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 texel = 1.0 / size;
	float threshold = glare0.x;
	float smoothness = glare0.y;
	float maximum = glare0.z;
	int quality = int(glare0.w); // input pixels per highlight pixel, along each axis: 1, 2 or 4
	vec2 start = texCoord * size - 0.5 * float(quality);
	// Average the quality x quality input pixels under this one. A bilinear read at the
	// corner between 2 x 2 pixels gives their average, so Medium needs 1 read and Low
	// 2 x 2. High reads the one pixel at its centre.
	float span = quality == 1 ? 1.0 : 2.0;
	int taps = quality == 1 ? 1 : quality / 2;
	vec3 c = vec3(0.0);
	for (int j = 0; j < taps; j++) {
		for (int i = 0; i < taps; i++) {
			c += textureLod(tex, (start + (vec2(float(i), float(j)) + 0.5) * span) * texel, 0.0).rgb;
		}
	}
	c /= float(taps * taps);

	float m = max(c.r, max(c.g, c.b));
	float k = knee(m - threshold, smoothness);
	if (maximum >= 0.0) k = maximum - knee(maximum - k, smoothness);
	fragColor = vec4(m > 0.0 ? c * (k / m) : vec3(0.0), 1.0);
}
