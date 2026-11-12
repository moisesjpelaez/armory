#version 450
// World pass of the Viewport renderer: draws the sky where no surface is.
// It runs after the material pass and before the lighting pass.
// Input: the world image (envmap) and the material pass's depth.
// Output: the sky colour into the lit image, and the sky's screen motion into the
// motion target for temporal anti-aliasing.

#include "compiled.inc"
#include "vpraster_common.inc"

uniform mat4 invVP;
uniform vec3 u_viewPosition;
uniform sampler2D envmap;
uniform float strength;
uniform mat4 armVP;     // unjittered, this frame
uniform mat4 armPrevVP; // unjittered, last frame
uniform vec4 u_armViewDir; // xyz: towards the camera, w: 1 for an orthographic camera
uniform sampler2D gbufferDepth; // the material pass's depth: 1 where no surface is

in vec2 texCoord;
layout(location = 0) out vec4 velocity;  // vpraster_gbuffer4, the pass's first target (RenderPathViewportRaster)
layout(location = 1) out vec4 fragColor; // vpraster_hdr

// The same lookup as the lighting pass (arm_latlong after u_envMatrix, see
// RasterEnvironment), so the sky and the world lighting always agree
uniform mat4 u_envMatrix;

void main() {
	// Only the sky. Where a surface is, the material pass already wrote the motion and
	// the lighting pass writes the colour.
	if (textureLod(gbufferDepth, texCoord, 0.0).r < 1.0) discard;

	// The far plane's point under this pixel gives the direction. An orthographic camera
	// looks along one direction for every pixel.
	vec3 dir = u_armViewDir.w > 0.5 ? -u_armViewDir.xyz : arm_world_position(texCoord, 1.0, invVP) - u_viewPosition;
	fragColor = vec4(textureLod(envmap, arm_latlong(normalize((u_envMatrix * vec4(dir, 0.0)).xyz)), 0.0).rgb * strength, 1.0);

	// The sky is infinitely far away, so only the camera's rotation moves it. An
	// orthographic camera sees one sky colour and gets no motion (projecting a
	// direction there would give w = 0).
	vec2 motion = vec2(0.0);
	if (u_armViewDir.w < 0.5) {
		motion = arm_motion(armVP * vec4(dir, 0.0), armPrevVP * vec4(dir, 0.0));
	}
	velocity = vec4(motion, 0.0, 1.0);
}
