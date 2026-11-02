#version 450

uniform sampler2D tex;

in vec2 texCoord;
out vec4 fragColor;

// Linear HDR -> display. For now a plain sRGB encode; Blender's colour
// management (view transform, look, exposure, gamma) replaces it.
void main() {
	vec3 color = max(textureLod(tex, texCoord, 0.0).rgb, vec3(0.0));
	vec3 low = color * 12.92;
	vec3 high = 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055;
	fragColor = vec4(mix(low, high, step(vec3(0.0031308), color)), 1.0);
}
