// Material pass of the Viewport renderer: the GLSL of the arm_gbuffer nodes
// (arm_gbuffer.mtlx). Each material's MaterialX shader ends in one of them.
// Input: the material's surface values. Output: the material images (G-buffer),
// which the lighting pass reads. glsl_rewrite.gbuffer_output() writes these variables
// to the render targets:
//   arm_gbuffer0  base colour, metalness
//   arm_gbuffer1  shading normal, triangle normal (both octahedral, world space)
//   arm_gbuffer2  specular tint, roughness
//   arm_gbuffer3  emission (colour x luminance), specular level
//   arm_gbuffer4  specular IOR, in z of the motion target (x and y hold the motion)
vec4 arm_gbuffer0;
vec4 arm_gbuffer1;
vec4 arm_gbuffer2;
vec4 arm_gbuffer3;
float arm_gbuffer4;
// Blended materials (arm_gbuffer_blended) light the values themselves:
// glsl_rewrite.blended_output() passes them and these two to arm_shade()
vec3 arm_position;
float arm_opacity = 1.0;

// Shared helpers: arm_octahedral() and arm_ign() here, and what the shading code of
// blended materials needs (lighting.shading_library()). MaterialX resolves the
// include itself (see mx_codegen.py).
#include "vpraster_common.inc"

void arm_gbuffer(vec3 base_color, float base_metalness, float specular_weight, vec3 specular_color,
                 float specular_roughness, float specular_ior, float emission_luminance, vec3 emission_color,
                 vec3 geometry_normal, vec3 position, out vec4 result) {
	vec3 N = normalize(geometry_normal);
	// The triangle's own normal, for the shadow lookup: the shadow map holds the flat
	// triangles, not the smooth shading normal. It faces the same side as the shading
	// normal. A triangle seen edge-on or smaller than a pixel has no usable
	// derivative; the shading normal is then the best estimate and avoids writing NaN.
	vec3 c = cross(dFdx(position), dFdy(position));
	float lengthSq = dot(c, c);
	vec3 facet = lengthSq > 1e-24 ? c * inversesqrt(lengthSq) : N;
	if (dot(facet, N) < 0.0) facet = -facet;
	arm_gbuffer0 = vec4(base_color, base_metalness);
	arm_gbuffer1 = vec4(arm_octahedral(N), arm_octahedral(facet));
	arm_gbuffer2 = vec4(specular_color, specular_roughness);
	arm_gbuffer3 = vec4(emission_color * emission_luminance, specular_weight);
	arm_gbuffer4 = specular_ior;
	arm_position = position;
	result = vec4(0.0);
}

// Frame number (RasterTaa), so the cut-out pattern changes every frame
uniform float u_armFrame;

// Materials with alpha (Eevee's Dithered render method): drops the pixel when its
// opacity is below a noise threshold that changes per pixel and frame. Temporal
// anti-aliasing averages the frames into the partial coverage.

void arm_gbuffer_cutout(vec3 base_color, float base_metalness, float specular_weight, vec3 specular_color,
                        float specular_roughness, float specular_ior, float emission_luminance, vec3 emission_color,
                        vec3 geometry_normal, vec3 position, float opacity, out vec4 result) {
	if (opacity <= arm_ign(gl_FragCoord.xy, u_armFrame)) discard;
	arm_gbuffer(base_color, base_metalness, specular_weight, specular_color, specular_roughness, specular_ior,
	            emission_luminance, emission_color, geometry_normal, position, result);
}

// Render Method: Blended. The same shader lights the pixel, which is then blended over
// what is behind it by its opacity (glsl_rewrite.blended_output()). It writes no
// material images.
void arm_gbuffer_blended(vec3 base_color, float base_metalness, float specular_weight, vec3 specular_color,
                         float specular_roughness, float specular_ior, float emission_luminance, vec3 emission_color,
                         vec3 geometry_normal, vec3 position, float opacity, out vec4 result) {
	arm_gbuffer(base_color, base_metalness, specular_weight, specular_color, specular_roughness, specular_ior,
	            emission_luminance, emission_color, geometry_normal, position, result);
	arm_opacity = clamp(opacity, 0.0, 1.0);
}
