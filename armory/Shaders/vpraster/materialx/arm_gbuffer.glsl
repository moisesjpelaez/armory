// Material images (G-buffer) of the Viewport renderer, see arm_gbuffer.mtlx
// (arm_gbuffer, and arm_gbuffer_cutout for materials with alpha).
// glsl_rewrite.gbuffer_output() writes these to the render targets:
//   arm_gbuffer0 = base colour, metalness
//   arm_gbuffer1 = shading normal, triangle normal (both octahedral, world space)
//   arm_gbuffer2 = specular tint, roughness
//   arm_gbuffer3 = emission (colour * luminance), specular level
//   arm_gbuffer4 = specular IOR (z of the velocity target, x and y = motion)
vec4 arm_gbuffer0;
vec4 arm_gbuffer1;
vec4 arm_gbuffer2;
vec4 arm_gbuffer3;
float arm_gbuffer4;
// Blended materials (arm_gbuffer_blended) shade these themselves:
// glsl_rewrite.blended_output() passes them to arm_shade()
vec3 arm_position;
float arm_opacity = 1.0;

vec2 arm_octahedral(vec3 n)
{
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 folded = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return n.z >= 0.0 ? n.xy : folded;
}

void arm_gbuffer(vec3 base_color, float base_metalness, float specular_weight, vec3 specular_color,
                 float specular_roughness, float specular_ior, float emission_luminance, vec3 emission_color,
                 vec3 geometry_normal, vec3 position, out vec4 result)
{
    vec3 N = normalize(geometry_normal);
    // The triangle's own normal: the shadow map holds the flat triangles, not the
    // smooth shading normal. Faces the same side as the shading normal.
    // A triangle seen edge-on, or smaller than a pixel, has no usable derivative:
    // its shading normal is the best estimate (and avoids writing NaN).
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

#include "vpraster_common.inc"

// Frame index (RasterTaa), so the cut-out pattern changes every frame
uniform float u_armFrame;

void arm_gbuffer_cutout(vec3 base_color, float base_metalness, float specular_weight, vec3 specular_color,
                        float specular_roughness, float specular_ior, float emission_luminance, vec3 emission_color,
                        vec3 geometry_normal, vec3 position, float opacity, out vec4 result)
{
    if (opacity <= arm_ign(gl_FragCoord.xy, u_armFrame)) discard;
    arm_gbuffer(base_color, base_metalness, specular_weight, specular_color, specular_roughness, specular_ior,
                emission_luminance, emission_color, geometry_normal, position, result);
}

// Render Method: Blended. The pixel is lit in the same shader and blended over
// what is behind it by its opacity (glsl_rewrite.blended_output()); it doesn't
// write the material images.
void arm_gbuffer_blended(vec3 base_color, float base_metalness, float specular_weight, vec3 specular_color,
                         float specular_roughness, float specular_ior, float emission_luminance, vec3 emission_color,
                         vec3 geometry_normal, vec3 position, float opacity, out vec4 result)
{
    arm_gbuffer(base_color, base_metalness, specular_weight, specular_color, specular_roughness, specular_ior,
                emission_luminance, emission_color, geometry_normal, position, result);
    arm_opacity = clamp(opacity, 0.0, 1.0);
}
