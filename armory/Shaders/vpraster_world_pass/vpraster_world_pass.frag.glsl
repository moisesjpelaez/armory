#version 450

#include "compiled.inc"
#include "vpraster_common.inc"

uniform mat4 invVP;
uniform vec3 eye;
uniform sampler2D envmap;
uniform float strength;
uniform mat4 armVP;     // unjittered, this frame
uniform mat4 armPrevVP; // unjittered, last frame
uniform vec4 viewDir;   // xyz: towards the camera, w: 1 for an orthographic camera

in vec2 texCoord;
layout(location = 0) out vec4 velocity;  // vpraster_gbuffer4, the pass's first target (RenderPathViewportRaster)
layout(location = 1) out vec4 fragColor; // vpraster_hdr

// Same lookup as the lighting pass (arm_latlong after envMatrix, RasterUniforms),
// so the sky and the world lighting always agree
uniform mat4 envMatrix;

void main() {
	vec2 ndc = texCoord * 2.0 - 1.0;
	#ifdef _InvY
	ndc.y = -ndc.y;
	#endif
	vec4 world = invVP * vec4(ndc, 1.0, 1.0);
	// Orthographic cameras look along one direction for every pixel
	vec3 dir = viewDir.w > 0.5 ? -viewDir.xyz : world.xyz / world.w - eye;
	fragColor = vec4(textureLod(envmap, arm_latlong(normalize((envMatrix * vec4(dir, 0.0)).xyz)), 0.0).rgb * strength, 1.0);

	// The sky is infinitely far: only camera rotation moves it (an orthographic
	// camera sees one sky colour, and projecting a direction there gives w = 0)
	vec2 motion = vec2(0.0);
	if (viewDir.w < 0.5) {
		motion = arm_motion(armVP * vec4(dir, 0.0), armPrevVP * vec4(dir, 0.0));
	}
	velocity = vec4(motion, 0.0, 1.0);
}
