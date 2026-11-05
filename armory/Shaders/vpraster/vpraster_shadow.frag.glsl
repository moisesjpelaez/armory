#version 450
// Shadow tile depth (vpraster_shadow.vert.glsl): the view's linear depth 0..1

in float depth;
out vec4 fragColor;

void main() {
	fragColor = vec4(depth, 0.0, 0.0, 1.0);
}
