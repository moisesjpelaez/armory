#version 450
// Depth-only pass into a shadow tile (armory.renderpath.viewport.raster.RasterShadows),
// resolved by blender/arm/viewport/raster/vertex.py (ARM_SKIN_*: skinned mesh, vpraster_skin.inc).
// The tile matrix maps world space straight to clip space. The lighting pass reads
// the atlas's depth as the view's linear depth 0..1: an orthographic tile matrix
// gives it as is; perspective views (ARM_SHADOW_PERSPECTIVE) pass it on to the pixel
// shader (vpraster_shadow_perspective.frag.glsl), which writes it.

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
	armBones = ivec4(bone * 32767.0 + 0.5);
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
