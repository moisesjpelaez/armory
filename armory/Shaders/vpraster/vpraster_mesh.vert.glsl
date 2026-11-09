#version 450
// Vertex shader of the material pass: places a mesh on screen and passes the pixel
// shader what its material needs (positions, normals, tangent, screen motion).
// blender/arm/viewport/raster/vertex.py turns this file into each material's shader:
//   ARM_TEXCOORD   the pixel shader reads texture coordinates
//   ARM_SKIN_*     skinned mesh (see vpraster_skin.inc)
// vertex.py replaces the @varyings marker line with the outputs and the @writes marker
// line with their values, in the pixel shader's order: Direct3D 11 links the two
// stages by position, not by name. vertex.py reads the marker lines and the local
// variable names in main(), so do not rename or reformat them.
// Armory packs mesh data: pos.xyz plus nor.z in a short4norm, nor.xy in a short2norm,
// texture coordinates scaled by texUnpack.

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
// For the screen motion that temporal anti-aliasing needs: the view-projection without
// jitter, this frame and last frame, and last frame's world matrix
uniform mat4 armVP;
uniform mat4 armPrevVP;
uniform mat4 prevW;

#include "vpraster_skin.inc"

// @varyings

void main() {
	// Object space after skinning (Texture Coordinate > Object in Blender)
	vec3 objectPos = pos.xyz * posUnpack;
	vec3 objectNor = vec3(nor.xy, pos.w);
	vec3 prevObjectPos = objectPos;
#ifdef ARM_SKIN
	armBones = arm_bone_indices(bone);
	vec3 prevNor;
	arm_skin(objectPos, objectNor, true, prevObjectPos, prevNor);
	arm_skin(objectPos, objectNor, false, objectPos, objectNor);
#endif
	vec4 positionWorld = W * vec4(objectPos / posUnpack, 1.0);
	vec3 normalWorld = normalize(N * objectNor);
	// Armory exports no tangents, so use any unit vector perpendicular to the normal.
	// It must never be parallel to the normal, because MaterialX normalizes
	// T - N * dot(T, N), which is then zero.
	vec3 helper = abs(normalWorld.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangentWorld = normalize(cross(helper, normalWorld));
	// @writes
	gl_Position = VP * positionWorld;
}
