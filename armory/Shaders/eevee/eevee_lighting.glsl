// Lighting pass of the Eevee renderer: Blender's Principled BSDF as Eevee shades
// it, for one pixel of the material images (materialx/arm_gbuffer.glsl).
// lighting.py puts eevee_specular.glsl (arm_dfg, arm_lamp_lobe, arm_lamp_cosine)
// and eevee_lights.glsl (arm_get_light, arm_light, shadows) before this file.
//
// Model, as measured on Eevee (materialx-recon):
//   dielectric: F0 = specular level * ((ior - 1) / (ior + 1))^2, F90 = min(1, F0 / 0.0125),
//               reflectance = (F0 * A + F90 * B) * comp, tinted by the specular colour;
//               the diffuse below it is weighted by 1 - reflectance
//   metal:      F0 = base colour, F90 = 1, weighted by the specular level
//   blend:      dielectric and metal mixed by metalness, then emission added
//   diffuse:    Lambert (Diffuse Roughness 0)
//   lamps:      reflectance * the lamp's lobe; diffuse * the lamp's cosine / pi
//   world:      reflectance * prefiltered radiance; diffuse * irradiance

// Eevee's light intensity and clamping (scene.eevee), set by the engine:
// x = intensity, y = clamp (0 = off). Measured Eevee behaviour: the clamp scales
// the colour down by its brightest channel (keeps the hue) and the intensity
// applies after it. Direct: the summed reflected light of all lights. Indirect:
// the incoming world light, before the BSDF.
uniform vec2 u_armDirect;
uniform vec2 u_armIndirect;

vec3 arm_clamp_scale(vec3 color, vec2 settings)
{
    float peak = max(color.r, max(color.g, color.b));
    if (settings.y > 0.0 && peak > settings.y) color *= settings.y / peak;
    return color * settings.x;
}

// Direction towards the viewer; with an orthographic camera every view ray is
// parallel. u_armViewDir: xyz = towards the camera, w = 1 for an orthographic
// camera (set by the engine).
uniform vec3 u_viewPosition;
uniform vec4 u_armViewDir;

vec3 arm_view_direction(vec3 position)
{
    return u_armViewDir.w > 0.5 ? u_armViewDir.xyz : normalize(u_viewPosition - position);
}

in vec2 texCoord;
uniform sampler2D gbuffer0;
uniform sampler2D gbuffer1;
uniform sampler2D gbuffer2;
uniform sampler2D gbuffer3;
uniform sampler2D gbuffer4;
uniform sampler2D gbufferDepth;
uniform mat4 invVP;

// World lighting (EeveeUniforms): latitude-longitude maps, `u_envMatrix` maps
// Blender's directions to the maps' frame
uniform mat4 u_envMatrix;
uniform sampler2D u_envRadiance;
uniform sampler2D u_envIrradiance;
uniform float u_envLightIntensity;
uniform int u_envRadianceMips;
uniform int u_numActiveLightSources;

out vec4 fragColor;

const float ARM_EPS = 1e-8;

vec3 arm_decode_octahedral(vec2 e)
{
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

vec3 arm_world_lookup(vec3 dir, float lod, sampler2D map)
{
    vec2 uv = arm_latlong(normalize((u_envMatrix * vec4(dir, 0.0)).xyz));
    return arm_clamp_scale(textureLod(map, uv, lod).rgb, u_armIndirect) * u_envLightIntensity;
}

// Mip of the prefiltered radiance for a GGX alpha
float arm_world_lod(float alpha)
{
    float bias = alpha < 0.25 ? sqrt(alpha) : 0.5 * alpha + 0.375;
    return bias * float(u_envRadianceMips - 1);
}

// Directional albedo of a specular lobe with Eevee's multiple-scattering term
vec3 arm_reflectance(float NdotV, float alpha, vec3 F0, vec3 F90)
{
    vec2 ab = arm_dfg(NdotV, alpha);
    vec3 favg = F0 + (1.0 - F0) / 21.0;
    return (F0 * ab.x + F90 * ab.y) / (1.0 - favg * (1.0 - ab.x - ab.y));
}

void main()
{
    float depth = textureLod(gbufferDepth, texCoord, 0.0).r;
    if (depth == 1.0) discard; // sky: the world pass drew it
    vec4 g0 = textureLod(gbuffer0, texCoord, 0.0);
    vec4 g1 = textureLod(gbuffer1, texCoord, 0.0);
    vec4 g2 = textureLod(gbuffer2, texCoord, 0.0);
    vec4 g3 = textureLod(gbuffer3, texCoord, 0.0);
    vec4 g4 = textureLod(gbuffer4, texCoord, 0.0);

    vec2 ndc = texCoord * 2.0 - 1.0;
#ifdef _InvY
    ndc.y = -ndc.y;
#endif
    vec4 world = invVP * vec4(ndc, depth * 2.0 - 1.0, 1.0);
    vec3 P = world.xyz / world.w;
    vec3 V = arm_view_direction(P);
    vec3 N = arm_decode_octahedral(g1.xy);
    if (dot(N, V) < 0.0) N = -N;
    vec3 geomNormal = arm_decode_octahedral(g1.zw); // the triangle's own normal (shadows)

    vec3 baseColor = max(g0.rgb, 0.0);
    float metalness = g0.a;
    vec3 tint = max(g2.rgb, 0.0);
    float alpha = clamp(g2.a * g2.a, ARM_EPS, 1.0);
    vec3 emission = g3.rgb;
    float specularLevel = g3.a;
    float ior = g4.z;

    float NdotV = clamp(dot(N, V), ARM_EPS, 1.0);
    float f0 = clamp(specularLevel * pow((ior - 1.0) / (ior + 1.0), 2.0), 0.0, 0.99999);
    vec3 dielectricReflectance = arm_reflectance(NdotV, alpha, vec3(f0), vec3(min(1.0, f0 / 0.0125)));
    vec3 diffuseWeight = 1.0 - dielectricReflectance;
    vec3 metalReflectance = arm_reflectance(NdotV, alpha, baseColor, vec3(1.0)) * specularLevel;
    vec3 specularColor = mix(dielectricReflectance * tint, metalReflectance, metalness);
    vec3 diffuseColor = baseColor * diffuseWeight * (1.0 - metalness);

    vec3 direct = vec3(0.0);
    int lights = min(u_numActiveLightSources, MAX_LIGHT_SOURCES);
    for (int i = 0; i < lights; i++)
    {
        ArmLamp lamp;
        arm_light(arm_get_light(i), P, geomNormal, lamp);
        if (lamp.intensity == vec3(0.0)) continue; // outside its reach or in full shadow
        vec3 L = lamp.direction;
        float NdotL = clamp(dot(N, L), ARM_EPS, 1.0);
        vec3 response = specularColor * arm_lamp_lobe(lamp, N, V, L, NdotV, alpha)
                      + diffuseColor * arm_lamp_cosine(lamp, N, NdotL) / M_PI;
        direct += lamp.intensity * response;
    }

    vec3 color = arm_clamp_scale(direct, u_armDirect);
    color += specularColor * arm_world_lookup(-reflect(V, N), arm_world_lod(alpha), u_envRadiance);
    color += diffuseColor * arm_world_lookup(N, 0.0, u_envIrradiance);
    color += emission;
    fragColor = vec4(color, 1.0);
}
