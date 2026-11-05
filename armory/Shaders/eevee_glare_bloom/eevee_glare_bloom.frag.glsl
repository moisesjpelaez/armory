#version 450

// Glare node, Bloom: the glare, at the highlights' resolution (EeveeCompositor).
// As measured in Blender 5.2: the average of the highlights and every level,
// each level brought up with four bilinear taps half a texel around this pixel.
// Then the node's Saturation (HSV saturation, largest channel kept), Tint and
// Strength.

uniform sampler2D hl;
uniform sampler2D lev1;
uniform sampler2D lev2;
uniform sampler2D lev3;
uniform sampler2D lev4;
uniform sampler2D lev5;
uniform sampler2D lev6;
uniform sampler2D lev7;
uniform sampler2D lev8;
uniform sampler2D lev9;
uniform sampler2D lev10;
uniform sampler2D lev11;
uniform vec4 glare1;    // strength, saturation, 1 / levels, levels (the highlights included)
uniform vec4 glareTint;

in vec2 texCoord;
out vec4 fragColor;

#define UP(t) (0.25 * (textureLod(t, texCoord + vec2(-0.5, -0.5) / vec2(textureSize(t, 0)), 0.0).rgb + \
                       textureLod(t, texCoord + vec2(0.5, -0.5) / vec2(textureSize(t, 0)), 0.0).rgb + \
                       textureLod(t, texCoord + vec2(-0.5, 0.5) / vec2(textureSize(t, 0)), 0.0).rgb + \
                       textureLod(t, texCoord + vec2(0.5, 0.5) / vec2(textureSize(t, 0)), 0.0).rgb))

void main() {
	int n = int(glare1.w);
	vec3 sum = textureLod(hl, texCoord, 0.0).rgb;
	if (n > 1) sum += UP(lev1);
	if (n > 2) sum += UP(lev2);
	if (n > 3) sum += UP(lev3);
	if (n > 4) sum += UP(lev4);
	if (n > 5) sum += UP(lev5);
	if (n > 6) sum += UP(lev6);
	if (n > 7) sum += UP(lev7);
	if (n > 8) sum += UP(lev8);
	if (n > 9) sum += UP(lev9);
	if (n > 10) sum += UP(lev10);
	if (n > 11) sum += UP(lev11);
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
