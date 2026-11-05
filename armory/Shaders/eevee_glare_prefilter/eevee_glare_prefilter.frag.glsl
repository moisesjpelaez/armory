#version 450

// Glare node, first pass (EeveeCompositor): the highlights of the Glare's input,
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
	int f = int(glare0.w);
	vec2 start = texCoord * size - 0.5 * float(f);
	vec3 c = vec3(0.0);
	for (int j = 0; j < f; j++) {
		for (int i = 0; i < f; i++) {
			c += textureLod(tex, (start + vec2(float(i), float(j)) + 0.5) / size, 0.0).rgb;
		}
	}
	c /= float(f * f);

	float m = max(c.r, max(c.g, c.b));
	float s = glare0.y;
	float k = knee(m - glare0.x, s);
	float maximum = glare0.z;
	if (maximum >= 0.0) k = maximum - knee(maximum - k, s);
	fragColor = vec4(m > 0.0 ? c * (k / m) : vec3(0.0), 1.0);
}
