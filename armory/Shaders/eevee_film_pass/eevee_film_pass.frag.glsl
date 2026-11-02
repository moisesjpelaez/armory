#version 450

uniform sampler2D tex;
uniform sampler2D lut;
uniform float lutSize; // 0 until the table is loaded
uniform vec2 lutStops; // log2 shaper range: min stop, max stop
uniform float exposure; // 2^exposure
uniform float invGamma;

in vec2 texCoord;
out vec4 fragColor;

// Linear HDR -> display with Blender's colour management, baked from its
// OpenColorIO config (blender/arm/eevee/color.py): exposure, then display +
// view transform + look through the table, then gamma.

vec3 lookup(vec3 linear) {
	vec3 t = clamp((log2(max(linear, vec3(1e-10))) - lutStops.x) / (lutStops.y - lutStops.x), 0.0, 1.0);
	vec3 s = t * (lutSize - 1.0);
	float b0 = floor(s.b);
	float b1 = min(b0 + 1.0, lutSize - 1.0);
	float width = lutSize * lutSize;
	vec2 uv0 = vec2((s.r + b0 * lutSize + 0.5) / width, (s.g + 0.5) / lutSize);
	vec2 uv1 = vec2((s.r + b1 * lutSize + 0.5) / width, (s.g + 0.5) / lutSize);
	return mix(textureLod(lut, uv0, 0.0).rgb, textureLod(lut, uv1, 0.0).rgb, s.b - b0);
}

vec3 srgb(vec3 color) {
	vec3 low = color * 12.92;
	vec3 high = 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055;
	return mix(low, high, step(vec3(0.0031308), color));
}

void main() {
	vec3 color = max(textureLod(tex, texCoord, 0.0).rgb, vec3(0.0)) * exposure;
	color = lutSize > 0.0 ? lookup(color) : srgb(color);
	fragColor = vec4(pow(max(color, vec3(0.0)), vec3(invGamma)), 1.0);
}
