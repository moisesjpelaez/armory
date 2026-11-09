#version 450
// Pixel shader of the perspective shadow views (spot, point and area lights), after
// vpraster_shadow.vert.glsl with ARM_SHADOW_PERSPECTIVE. It writes the view's linear
// depth 0..1 instead of the perspective depth, because the lighting pass compares
// linear depth (vpraster_lights.glsl). Both rise together, so the depth test still
// keeps the nearest caster. The colour is not written (see the shadow contexts in
// materials.py).

in float depth;
out vec4 fragColor;

void main() {
	gl_FragDepth = clamp(depth, 0.0, 1.0);
	fragColor = vec4(1.0);
}
