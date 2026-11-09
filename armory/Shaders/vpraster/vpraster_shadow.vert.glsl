#version 450
// Vertex shader of the shadow maps: draws a mesh's depth into one tile of the shadow
// atlas, as seen from a light (RasterShadows draws the tiles before the lighting).
// vertex.py sets the options: ARM_SKIN_* for a skinned mesh (see vpraster_skin.inc),
// ARM_SHADOW_PERSPECTIVE for a perspective view (spot, point and area lights).
// shadowVP, the tile matrix, maps world space straight to the tile's clip space.
// The lighting pass reads the atlas as each view's linear depth 0..1. An orthographic
// tile matrix gives that depth as is. A perspective view computes it here (shadowDepth)
// and passes it to vpraster_shadow_perspective.frag.glsl, which writes it.

in vec4 pos;
#ifdef ARM_SKIN
in vec4 bone;
in vec4 weight;
#endif

uniform mat4 W;
uniform mat4 shadowVP;
#ifdef ARM_SHADOW_PERSPECTIVE
uniform vec4 shadowDepth;
#endif
#ifdef ARM_SKIN
uniform float posUnpack;
#endif

#include "vpraster_skin.inc"

#ifdef ARM_SHADOW_PERSPECTIVE
out float depth;
#endif

void main() {
#ifdef ARM_SKIN
	armBones = arm_bone_indices(bone);
	vec3 objectPos;
	vec3 unusedNormal; // shadows need positions only
	arm_skin(pos.xyz * posUnpack, vec3(0.0), false, objectPos, unusedNormal);
	vec4 positionWorld = W * vec4(objectPos / posUnpack, 1.0);
#else
	vec4 positionWorld = W * vec4(pos.xyz, 1.0);
#endif
	gl_Position = shadowVP * positionWorld;
#ifdef ARM_SHADOW_PERSPECTIVE
	depth = dot(shadowDepth.xyz, positionWorld.xyz) + shadowDepth.w;
#endif
}
