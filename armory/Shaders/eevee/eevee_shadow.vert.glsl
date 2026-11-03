#version 450
// Depth-only pass into a shadow tile (armory.renderpath.eevee.EeveeShadows),
// resolved by blender/arm/eevee/vertex.py (ARM_SKIN_*: skinned mesh, eevee_skin.inc).
// The tile matrix maps world space straight to clip space; the pixel stage stores
// the view's linear depth 0..1 (shadowDepth row) in an R32 target.

in vec4 pos;
#ifdef ARM_SKIN
in vec4 bone;
in vec4 weight;
#endif

uniform mat4 W;
uniform mat4 shadowVP;
uniform vec4 shadowDepth;
#ifdef ARM_SKIN
uniform float posUnpack;
#endif

#include "eevee_skin.inc"

out float depth;

void main() {
#ifdef ARM_SKIN
	armBones = ivec4(bone * 32767.0 + 0.5);
	vec3 objectPos;
	vec3 unusedNormal; // shadows need positions only
	arm_skin(pos.xyz * posUnpack, vec3(0.0), false, objectPos, unusedNormal);
	vec4 positionWorld = W * vec4(objectPos / posUnpack, 1.0);
#else
	vec4 positionWorld = W * vec4(pos.xyz, 1.0);
#endif
	gl_Position = shadowVP * positionWorld;
	depth = dot(shadowDepth.xyz, positionWorld.xyz) + shadowDepth.w;
}
