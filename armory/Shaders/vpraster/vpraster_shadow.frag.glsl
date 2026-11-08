#version 450
// Shadow tile (vpraster_shadow.vert.glsl): only the depth buffer is drawn. The atlas's
// colour image is there because a render target needs one; the pipeline writes no
// colour (blender/arm/viewport/raster/materials.py, the shadow context).

out vec4 fragColor;

void main() {
	fragColor = vec4(1.0);
}
