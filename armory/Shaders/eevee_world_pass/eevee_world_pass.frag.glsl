#version 450

#include "compiled.inc"

uniform mat4 invVP;
uniform vec3 eye;
uniform sampler2D envmap;
uniform float strength;

in vec2 texCoord;
out vec4 fragColor;

// Same lookup as the MaterialX shaders (mx_latlong_projection after u_envMatrix,
// which turns Blender's Z-up into MaterialX's Y-up), so the sky and the
// lighting always agree.
vec2 latlong(vec3 dir) {
	vec3 d = normalize(vec3(dir.x, dir.z, -dir.y));
	float latitude = -asin(d.y) / PI + 0.5;
	float longitude = atan(d.x, -d.z) / PI * 0.5 + 0.5;
	return vec2(longitude, latitude);
}

void main() {
	vec2 ndc = texCoord * 2.0 - 1.0;
	#ifdef _InvY
	ndc.y = -ndc.y;
	#endif
	vec4 world = invVP * vec4(ndc, 1.0, 1.0);
	vec3 dir = world.xyz / world.w - eye;
	fragColor = vec4(textureLod(envmap, latlong(dir), 0.0).rgb * strength, 1.0);
}
