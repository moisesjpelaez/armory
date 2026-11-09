#version 450
// Pixel shader of the orthographic shadow views (sun lights): only the depth matters.
// The colour output exists because the atlas's render target needs a colour image,
// but the pipeline does not write it (see the shadow context in materials.py).

out vec4 fragColor;

void main() {
	fragColor = vec4(1.0);
}
