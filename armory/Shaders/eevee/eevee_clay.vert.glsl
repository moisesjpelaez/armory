#version 450

in vec4 pos;
in vec2 nor;

uniform mat4 W;
uniform mat3 N;
uniform mat4 VP;

out vec3 vd_normalWorld;
out vec3 vd_positionWorld;

void main() {
	vec4 positionWorld = W * vec4(pos.xyz, 1.0);
	vd_positionWorld = positionWorld.xyz;
	vd_normalWorld = normalize(N * vec3(nor.xy, pos.w));
	gl_Position = VP * positionWorld;
}
