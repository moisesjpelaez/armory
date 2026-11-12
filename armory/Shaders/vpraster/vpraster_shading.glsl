// Surface shading of the Viewport renderer: Blender's Principled BSDF as Eevee shades
// it. arm_shade() (at the end) lights one surface point from its material image
// values, which materialx/arm_gbuffer.glsl writes. The lighting pass
// (vpraster_lighting.glsl) and blended materials (materials.py) both call it.
// lighting.py pastes vpraster_specular.glsl (highlights, reflectance table) and
// vpraster_lights.glsl (lights, shadows) before this file.
//
// The model, matching Eevee:
//   dielectric  F0 = specular level * ((ior - 1) / (ior + 1))^2, F90 = min(1, F0 / 0.0125).
//               Its reflectance is tinted by the specular colour. The diffuse under
//               it gets what it does not reflect (1 - reflectance).
//   metal       F0 = base colour, F90 = 1, scaled by the specular level.
//   mix         Dielectric and metal mixed by metalness, then emission added.
//   diffuse     Lambert (Diffuse Roughness 0).
//   lamps       Reflectance x the lamp's highlight lobe, diffuse x the lamp's cosine / pi.
//   world       Reflectance x the blurred world image, diffuse x the world's irradiance.

// Eevee's light intensity and clamp settings (scene.eevee), set by the engine.
// x: intensity. y: clamp (0 = off).
// As in Eevee, the clamp scales the colour down by its brightest channel, which keeps
// the hue, and the intensity applies after it. Direct: the summed light reflected
// from all lights. Indirect: the incoming world light, before the surface reflects it.
uniform vec2 u_armDirect;
uniform vec2 u_armIndirect;

vec3 arm_clamp_scale(vec3 color, vec2 settings) {
	float peak = max(color.r, max(color.g, color.b));
	if (settings.y > 0.0 && peak > settings.y) color *= settings.y / peak;
	return color * settings.x;
}

// Direction towards the viewer. An orthographic camera has the same direction for
// every point. u_armViewDir: xyz is towards the camera, w is 1 for an orthographic
// camera (set by the engine).
uniform vec3 u_viewPosition;
uniform vec4 u_armViewDir;

vec3 arm_view_direction(vec3 position) {
	return u_armViewDir.w > 0.5 ? u_armViewDir.xyz : normalize(u_viewPosition - position);
}


// World lighting, set by RasterEnvironment: a blurred radiance image with mipmaps (for
// reflections) and an irradiance image (for diffuse light), both latitude-longitude
// maps. u_envMatrix turns Blender's directions into the maps' frame.
uniform mat4 u_envMatrix;
uniform sampler2D u_envRadiance;
uniform sampler2D u_envIrradiance;
uniform float u_envLightIntensity;
uniform int u_envRadianceMips;

const float ARM_EPS = 1e-8;

// World light from direction `dir` (unit length) at mip `lod`, with the indirect
// clamp and intensity. u_envMatrix only swaps axes, so the turned direction stays
// unit length.
vec3 arm_world_lookup(vec3 dir, float lod, sampler2D map) {
	vec2 uv = arm_latlong((u_envMatrix * vec4(dir, 0.0)).xyz);
	return arm_clamp_scale(textureLod(map, uv, lod).rgb, u_armIndirect) * u_envLightIntensity;
}

// Mip of the blurred world image for a GGX alpha: rougher surfaces read blurrier
// mips. The curve is fitted to match Eevee.
float arm_world_lod(float alpha) {
	float bias = alpha < 0.25 ? sqrt(alpha) : 0.5 * alpha + 0.375;
	return bias * float(u_envRadianceMips - 1);
}

// Total reflectance of a glossy lobe, including light that bounces more than once
// inside the rough surface, as Eevee does (multiple-scattering compensation, Kulla
// and Conty 2017). ab = arm_dfg(NdotV, alpha), the same for the dielectric and the
// metal lobe.
vec3 arm_reflectance(vec2 ab, vec3 F0, vec3 F90) {
	// Hemispherical average of Schlick's Fresnel
	vec3 favg = F0 + (1.0 - F0) / 21.0;
	return (F0 * ab.x + F90 * ab.y) / (1.0 - favg * (1.0 - ab.x - ab.y));
}

// Lit colour of one surface point from its material image values (arm_gbuffer.glsl
// lists them) and its world position P. The lighting pass reads the values from the
// images. Blended materials (Render Method: Blended) compute them in their own shader.
// Both then shade the same way.
vec3 arm_shade(vec4 g0, vec4 g1, vec4 g2, vec4 g3, float ior, vec3 P) {
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

	float NdotV = clamp(dot(N, V), ARM_EPS, 1.0);
	float r = (ior - 1.0) / (ior + 1.0); // squared as r * r: pow() is undefined for the negative r of an IOR below 1
	float f0 = clamp(specularLevel * r * r, 0.0, 0.99999);
	vec2 ab = arm_dfg(NdotV, alpha);
	// F90 fades out as F0 nears 0 and is full from F0 = 0.0125; fitted to match Eevee
	vec3 dielectricReflectance = arm_reflectance(ab, vec3(f0), vec3(min(1.0, f0 / 0.0125)));
	vec3 diffuseWeight = 1.0 - dielectricReflectance;
	vec3 metalReflectance = arm_reflectance(ab, baseColor, vec3(1.0)) * specularLevel;
	vec3 specularColor = mix(dielectricReflectance * tint, metalReflectance, metalness);
	vec3 diffuseColor = baseColor * diffuseWeight * (1.0 - metalness);

	ArmLobe lobe = arm_lobe(N, V, NdotV, alpha); // the same for every lamp
	vec3 direct = vec3(0.0);
	int lights = min(u_numActiveLightSources, MAX_LIGHT_SOURCES);
	for (int i = 0; i < lights; i++) {
		ArmLamp lamp;
		arm_light(arm_get_light(i), P, geomNormal, lamp);
		if (lamp.intensity == vec3(0.0)) continue; // outside its reach or in full shadow
		vec3 L = lamp.direction;
		float NdotL = clamp(dot(N, L), ARM_EPS, 1.0);
		vec3 response = specularColor * arm_lamp_lobe(lamp, lobe, N, L)
		              + diffuseColor * arm_lamp_cosine(lamp, lobe, N, NdotL) / M_PI;
		direct += lamp.intensity * response;
	}

	vec3 color = arm_clamp_scale(direct, u_armDirect);
	color += specularColor * arm_world_lookup(-reflect(V, N), arm_world_lod(alpha), u_envRadiance);
	color += diffuseColor * arm_world_lookup(N, 0.0, u_envIrradiance);
	color += emission;
	return color;
}
