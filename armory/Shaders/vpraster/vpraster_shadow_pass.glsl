// Shadow pass of the Viewport renderer: the main() of the shadow pass's shader.
// It runs after the material pass and before the lighting pass, when at most 4 lights
// cast shadows (RasterLights.PASS_LIGHTS).
// Input: the depth and the triangle normals of the material images.
// Output: each pixel's visibility from each shadow-casting light, one channel per light
// (LightData.shadowChannel, set by RasterLights).
// It runs the lighting pass's own shadow code, arm_shadow() from vpraster_lights.glsl,
// which lighting.py pastes before this file. The lighting pass then reads this image
// (ARM_SHADOWS_FROM_PASS) and leaves its shadow code out, because unused code still
// slows a shader down; split this way, the work costs less in total.
// Versions: with or without spot, point and area shadows (ARM_SUN_SHADOWS_ONLY), as
// listed in lighting.py's docstring.

in vec2 texCoord;
uniform sampler2D gbuffer1;
uniform sampler2D gbufferDepth;
uniform mat4 invVP;

out vec4 fragColor;

void main() {
	float depth = textureLod(gbufferDepth, texCoord, 0.0).r;
	if (depth == 1.0) discard; // sky: the lighting pass skips it too
	vec4 g1 = textureLod(gbuffer1, texCoord, 0.0);

	vec3 P = arm_world_position(texCoord, depth, invVP);
	vec3 geomNormal = arm_decode_octahedral(g1.zw); // the triangle's own normal

	vec4 visibility = vec4(1.0);
	int lights = min(u_numActiveLightSources, MAX_LIGHT_SOURCES);
	for (int i = 0; i < lights; i++) {
		LightData light = arm_get_light(i);
		if (light.shadowChannel < 0.0) continue;
		float v = 1.0;
		if (light.kind == ARM_LIGHT_SUN) {
			v = arm_shadow(light, P, geomNormal, -light.direction);
		}
		else {
			// Only where the light reaches, as arm_light() skips the shadow elsewhere
			float distanceSq;
			vec3 direction = arm_light_direction(light, P, distanceSq);
			if (arm_light_reach(light, P, direction, distanceSq) > 0.0) v = arm_shadow(light, P, geomNormal, direction);
		}
		visibility = mix(visibility, vec4(v), arm_shadow_channel(light));
	}
	fragColor = visibility;
}
