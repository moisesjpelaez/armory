#version 450

// Glare node, Bloom: the next level at half resolution (ViewportCompositor). As
// measured in Blender 5.2: 13 bilinear taps around this pixel's centre (a corner
// of the larger level), weights 1/8 for the centre and the four inner taps, 1/16
// for the four edge taps, 1/32 for the four outer corners. Edges are extended.

uniform sampler2D tex;

in vec2 texCoord;
out vec4 fragColor;

vec3 tap(vec2 centre, vec2 size, float x, float y) {
	return textureLod(tex, (centre + vec2(x, y)) / size, 0.0).rgb;
}

void main() {
	vec2 size = vec2(textureSize(tex, 0));
	vec2 c = texCoord * size;
	vec3 sum = 0.125 * (tap(c, size, -1.0, -1.0) + tap(c, size, 1.0, -1.0) + tap(c, size, -1.0, 1.0) + tap(c, size, 1.0, 1.0) + tap(c, size, 0.0, 0.0));
	sum += 0.0625 * (tap(c, size, 0.0, 2.0) + tap(c, size, 0.0, -2.0) + tap(c, size, 2.0, 0.0) + tap(c, size, -2.0, 0.0));
	sum += 0.03125 * (tap(c, size, 2.0, 2.0) + tap(c, size, -2.0, 2.0) + tap(c, size, 2.0, -2.0) + tap(c, size, -2.0, -2.0));
	fragColor = vec4(sum, 1.0);
}
