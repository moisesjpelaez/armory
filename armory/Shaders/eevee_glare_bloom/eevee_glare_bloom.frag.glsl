#version 450

// Glare node, Bloom: the glare, at the highlights' resolution (EeveeCompositor).
// As measured in Blender 5.2: the highlights plus every level, summed from the
// coarsest up (Shaders/eevee_glare_up) and brought up here with the same 3 x 3
// tent, averaged. Then the node's Saturation (HSV saturation, largest channel
// kept), Tint and Strength.

uniform sampler2D hl;
uniform sampler2D up;   // the levels, summed (unused with one level)
uniform vec4 glare1;    // strength, saturation, 1 / levels, levels (the highlights included)
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;

vec3 tent(vec2 uv) {
	vec2 o = 0.5 / vec2(textureSize(up, 0));
	vec3 sum = 4.0 * textureLod(up, uv, 0.0).rgb;
	sum += 2.0 * (textureLod(up, uv + vec2(o.x, 0.0), 0.0).rgb + textureLod(up, uv - vec2(o.x, 0.0), 0.0).rgb +
	              textureLod(up, uv + vec2(0.0, o.y), 0.0).rgb + textureLod(up, uv - vec2(0.0, o.y), 0.0).rgb);
	sum += textureLod(up, uv + o, 0.0).rgb + textureLod(up, uv - o, 0.0).rgb +
	       textureLod(up, uv + vec2(o.x, -o.y), 0.0).rgb + textureLod(up, uv + vec2(-o.x, o.y), 0.0).rgb;
	return sum / 16.0;
}

void main() {
	vec3 sum = textureLod(hl, texCoord, 0.0).rgb;
	if (glare1.w > 1.5) sum += tent(texCoord);
	vec3 g = sum * glare1.z;

	// Saturation: the distance of each channel from the largest one, scaled
	float v = max(g.r, max(g.g, g.b));
	float lo = min(g.r, min(g.g, g.b));
	if (v > 0.0 && v > lo) {
		float s = (v - lo) / v;
		float scaled = clamp(s * glare1.y, 0.0, 1.0);
		g = v - (v - g) * (scaled / s);
	}
	fragColor = vec4(g * glareTint.rgb * glare1.x, 1.0);
}
