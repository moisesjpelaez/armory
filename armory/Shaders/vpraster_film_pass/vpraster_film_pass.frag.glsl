#version 450
// Film pass of the Viewport renderer, the last pass of the frame: turns the linear HDR
// image into display colours with Blender's colour management, then dithers.
// It runs after temporal anti-aliasing and draws to the screen.
// Input: `tex`, the resolved image. Output: display colours, and alpha for a
// transparent film.

#include "vpraster_common.inc"

uniform sampler2D tex;
uniform sampler2D lut;
uniform float lutSize;
uniform vec2 lutStops; // log2 range the table covers: lowest and highest stop

in vec2 texCoord;
uniform vec2 dither; // x: Blender's render.dither_intensity, y: frame index for the noise
out vec4 fragColor;

// Blender's colour management is baked into a 3D table from its OpenColorIO config
// (blender/arm/viewport/color.py): the display, view transform, look, exposure
// and gamma.
// lookup() reads the table: a 3D table laid out as lutSize slices side by side in a
// 2D image, indexed by log2 of the colour. It blends the two nearest blue slices.

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
	vec3 color = max(lookup(max(scene.rgb, vec3(0.0))), vec3(0.0));
	// Blender's dither, so smooth gradients do not break into 8-bit bands. As in
	// Blender, intensity 1 adds noise one 8-bit step wide (interleaved gradient noise).
	color += (arm_ign(gl_FragCoord.xy, dither.y) - 0.5) * dither.x / 255.0;
	// Alpha is 0 only where nothing was drawn over a transparent film
	fragColor = vec4(color, scene.a);
}
