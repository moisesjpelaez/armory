#version 450

in vec3 vd_normalWorld;
in vec3 vd_positionWorld;

out vec4 fragColor;

// Placeholder surface until the MaterialX shaders arrive: grey clay lit by one
// fixed directional light plus a constant ambient term, in linear HDR.
void main() {
	vec3 n = normalize(vd_normalWorld);
	vec3 lightDirection = normalize(vec3(0.4, 0.6, -0.7));
	float diffuse = max(dot(n, -lightDirection), 0.0);
	fragColor = vec4(vec3(0.8) * (diffuse * 0.8 + 0.15), 1.0);
}
