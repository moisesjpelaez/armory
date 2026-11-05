#version 450

// Glare node, Bloom: one step up (ViewportCompositor). As measured in Blender 5.2:
// the coarser levels, already summed, brought up with a 3 x 3 tent of bilinear
// taps half a coarse texel apart (weights 1, 2, 1 per axis), plus this level.

uniform sampler2D tex;   // the coarser levels, summed
uniform sampler2D level; // this level

in vec2 texCoord;
out vec4 fragColor;

vec3 tent(vec2 uv) {
	vec2 o = 0.5 / vec2(textureSize(tex, 0));
	vec3 sum = 4.0 * textureLod(tex, uv, 0.0).rgb;
	sum += 2.0 * (textureLod(tex, uv + vec2(o.x, 0.0), 0.0).rgb + textureLod(tex, uv - vec2(o.x, 0.0), 0.0).rgb +
	              textureLod(tex, uv + vec2(0.0, o.y), 0.0).rgb + textureLod(tex, uv - vec2(0.0, o.y), 0.0).rgb);
	sum += textureLod(tex, uv + o, 0.0).rgb + textureLod(tex, uv - o, 0.0).rgb +
	       textureLod(tex, uv + vec2(o.x, -o.y), 0.0).rgb + textureLod(tex, uv + vec2(-o.x, o.y), 0.0).rgb;
	return sum / 16.0;
}

void main() {
	fragColor = vec4(tent(texCoord) + textureLod(level, texCoord, 0.0).rgb, 1.0);
}
