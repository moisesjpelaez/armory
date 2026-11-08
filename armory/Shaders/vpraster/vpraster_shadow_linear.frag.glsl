#version 450
// Shadow tile of a perspective view (vpraster_shadow.vert.glsl with ARM_SHADOW_LINEAR):
// the depth buffer gets the view's linear depth 0..1, the depth the lighting pass
// compares (vpraster_lights.glsl), instead of the perspective depth. Both rise
// together, so the depth test keeps the nearest caster either way. No colour is
// written (blender/arm/viewport/raster/materials.py, the shadow contexts).

in float depth;
out vec4 fragColor;

void main() {
	gl_FragDepth = clamp(depth, 0.0, 1.0);
	fragColor = vec4(1.0);
}
