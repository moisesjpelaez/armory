#version 450

// Glare node, first pass (ViewportCompositor): the highlights of the Glare's input,
// at the node's Quality (Medium, Low: the average of the 2 x 2 or 4 x 4 input
// pixels under this pixel first, as Blender does). As measured in Blender 5.2:
// a pixel's brightness is its largest channel m, its highlight keeps its colour
// scaled by f(m) / m, with f(m) = m - threshold softened by a quadratic knee of
// half-width smoothness; Clamp caps f(m) at the maximum with the same knee.

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
	int f = int(glare0.w);
	vec2 start = texCoord * size - 0.5 * float(f);
	// The f x f input pixels under this one, averaged. From Medium on, a bilinear tap at
	// the corner between 2 x 2 pixels reads their average: 1 tap at Medium, 4 at Low
	// (High: the one pixel, at its centre)
	float span = f == 1 ? 1.0 : 2.0;
	int taps = f == 1 ? 1 : f / 2;
	vec3 c = vec3(0.0);
	for (int j = 0; j < taps; j++) {
		for (int i = 0; i < taps; i++) {
			c += textureLod(tex, (start + (vec2(float(i), float(j)) + 0.5) * span) * texel, 0.0).rgb;
		}
	}
	c /= float(taps * taps);

	float m = max(c.r, max(c.g, c.b));
	float s = glare0.y;
	float k = knee(m - glare0.x, s);
	float maximum = glare0.z;
	if (maximum >= 0.0) k = maximum - knee(maximum - k, s);
	fragColor = vec4(m > 0.0 ? c * (k / m) : vec3(0.0), 1.0);
}
