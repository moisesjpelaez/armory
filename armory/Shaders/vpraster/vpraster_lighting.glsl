// Lighting pass of the Viewport renderer: the main() of the lighting shader.
// It runs after the material pass and draws into the lit image (vpraster_hdr).
// Input: the material images gbuffer0..4 and the depth (see materialx/arm_gbuffer.glsl).
// Output: the lit colour of every pixel with a surface.
// lighting.py pastes this file after vpraster_common.inc, vpraster_specular.glsl,
// vpraster_lights.glsl and vpraster_shading.glsl, which provides arm_shade().

in vec2 texCoord;
uniform sampler2D gbuffer0;
uniform sampler2D gbuffer1;
uniform sampler2D gbuffer2;
uniform sampler2D gbuffer3;
uniform sampler2D gbuffer4;
uniform sampler2D gbufferDepth;
uniform mat4 invVP;

out vec4 fragColor;

void main() {
	float depth = textureLod(gbufferDepth, texCoord, 0.0).r;
	if (depth == 1.0) discard; // sky: the world pass already drew it
	vec4 g0 = textureLod(gbuffer0, texCoord, 0.0);
	vec4 g1 = textureLod(gbuffer1, texCoord, 0.0);
	vec4 g2 = textureLod(gbuffer2, texCoord, 0.0);
	vec4 g3 = textureLod(gbuffer3, texCoord, 0.0);
	vec4 g4 = textureLod(gbuffer4, texCoord, 0.0);

	vec3 P = arm_world_position(texCoord, depth, invVP);
	fragColor = vec4(arm_shade(g0, g1, g2, g3, g4.z, P), 1.0);
}
