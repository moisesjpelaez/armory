// Material images (G-buffer) of the Eevee renderer, see arm_gbuffer.mtlx.
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
    vec3 facet = normalize(cross(dFdx(position), dFdy(position)));
    if (dot(facet, N) < 0.0) facet = -facet;
    arm_gbuffer0 = vec4(base_color, base_metalness);
    arm_gbuffer1 = vec4(arm_octahedral(N), arm_octahedral(facet));
    arm_gbuffer2 = vec4(specular_color, specular_roughness);
    arm_gbuffer3 = vec4(emission_color * emission_luminance, specular_weight);
    arm_gbuffer4 = specular_ior;
    result = vec4(0.0);
}
