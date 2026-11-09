#version 450
// Material pass vertex stage (blender/arm/viewport/raster/vertex.py resolves the ARM_ options).
// Armory meshes are packed: pos.xyz + nor.z in a short4norm, nor.xy in a short2norm,
// texture coordinates scaled by texUnpack.
//   ARM_TEXCOORD     the pixel shader reads texture coordinates
//   ARM_SKIN_*       skinned mesh (vpraster_skin.inc)
// vertex.py writes the varyings the pixel shader declares at the @varyings and
// @writes lines, in the pixel shader's order: D3D11 links the stages by register.

in vec4 pos;
in vec2 nor;
#ifdef ARM_TEXCOORD
in vec2 tex;
#endif
#ifdef ARM_SKIN
in vec4 bone;
in vec4 weight;
#endif

uniform mat4 W;
uniform mat3 N;
uniform mat4 VP;
uniform float posUnpack;
#ifdef ARM_TEXCOORD
uniform float texUnpack;
#endif
// Unjittered view-projection now and last frame, and last frame's world matrix:
// the screen motion for temporal anti-aliasing
uniform mat4 armVP;
uniform mat4 armPrevVP;
uniform mat4 prevW;

#include "vpraster_skin.inc"

// @varyings

void main() {
	// Object space (Texture Coordinate > Object), after skinning
	vec3 objectPos = pos.xyz * posUnpack;
	vec3 objectNor = vec3(nor.xy, pos.w);
	vec3 prevObjectPos = objectPos;
#ifdef ARM_SKIN
	armBones = ivec4(bone * 32767.0 + 0.5);
	vec3 prevNor;
	arm_skin(objectPos, objectNor, true, prevObjectPos, prevNor);
	arm_skin(objectPos, objectNor, false, objectPos, objectNor);
#endif
	vec4 positionWorld = W * vec4(objectPos / posUnpack, 1.0);
	vec3 normalWorld = normalize(N * objectNor);
	// No tangents exported yet: any unit vector perpendicular to the normal.
	// It must never be parallel to it, MaterialX normalizes T - N * dot(T, N).
	vec3 helper = abs(normalWorld.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangentWorld = normalize(cross(helper, normalWorld));
	// @writes
	gl_Position = VP * positionWorld;
}
