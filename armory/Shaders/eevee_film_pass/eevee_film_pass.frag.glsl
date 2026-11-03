#version 450

#include "eevee_common.inc"

uniform sampler2D tex;
uniform sampler2D lut;
uniform float lutSize;
uniform vec2 lutStops; // log2 shaper range: min stop, max stop
uniform float exposure; // 2^exposure
uniform float invGamma;

in vec2 texCoord;
uniform vec2 dither; // x: Blender's render.dither_intensity, y: frame index for the noise
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

void main() {
	vec4 scene = textureLod(tex, texCoord, 0.0);
	vec3 color = max(scene.rgb, vec3(0.0)) * exposure;
	color = pow(max(lookup(color), vec3(0.0)), vec3(invGamma));
	// Blender's dither (measured: one 8-bit step of uniform noise at intensity 1), so
	// smooth gradients do not break into 8-bit bands; interleaved gradient noise
	color += (arm_ign(gl_FragCoord.xy, dither.y) - 0.5) * dither.x / 255.0;
	// Alpha is 0 only where nothing was drawn over a transparent film
	fragColor = vec4(color, scene.a);
}
