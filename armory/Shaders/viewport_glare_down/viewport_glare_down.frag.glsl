#version 450

// Glare node, Bloom: makes the next level at half resolution, from the second level
// on (ViewportCompositor; viewport_glare_firefly makes the first). It filters as Blender
// does: 13 bilinear reads around this pixel's centre, which is a texel corner of the
// larger level. Weights: 1/8 for the centre and the four inner reads, 1/16 for the
// four edge reads, 1/32 for the four outer corners. Edges are extended.

uniform sampler2D tex;

in vec2 texCoord;
out vec4 fragColor;

vec3 tap(vec2 centre, vec2 texel, float x, float y) {
	return textureLod(tex, (centre + vec2(x, y)) * texel, 0.0).rgb;
}

void main() {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 texel = 1.0 / size;
	vec2 c = texCoord * size;
	vec3 sum = 0.125 * (tap(c, texel, -1.0, -1.0) + tap(c, texel, 1.0, -1.0) + tap(c, texel, -1.0, 1.0) + tap(c, texel, 1.0, 1.0) + tap(c, texel, 0.0, 0.0));
	sum += 0.0625 * (tap(c, texel, 0.0, 2.0) + tap(c, texel, 0.0, -2.0) + tap(c, texel, 2.0, 0.0) + tap(c, texel, -2.0, 0.0));
	sum += 0.03125 * (tap(c, texel, 2.0, 2.0) + tap(c, texel, -2.0, 2.0) + tap(c, texel, 2.0, -2.0) + tap(c, texel, -2.0, -2.0));
	fragColor = vec4(sum, 1.0);
}
