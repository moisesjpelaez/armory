#version 450

// Glare node: the glare of a type summed in passes (Streaks, Simple Star, Sun
// Beams), scaled, then the node's Saturation (HSV saturation, largest channel
// kept), Tint and Strength, as for Bloom (ViewportCompositor).

uniform sampler2D tex;
uniform vec4 glare1; // strength, saturation, scale
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;

void main() {
	vec3 g = textureLod(tex, texCoord, 0.0).rgb * glare1.z;
	float v = max(g.r, max(g.g, g.b));
	float lo = min(g.r, min(g.g, g.b));
	if (v > 0.0 && v > lo) {
		float s = (v - lo) / v;
		float scaled = clamp(s * glare1.y, 0.0, 1.0);
		g = v - (v - g) * (scaled / s);
	}
	fragColor = vec4(g * glareTint.rgb * glare1.x, 1.0);
}
