// Shared by the Glare node's passes (Shaders/viewport_glare_*, ViewportCompositor).
// Copied next to the compiled shaders by blender/arm/viewport/raster/renderpath.py,
// which recompiles the passes when it changes.

// A tap that counts outside the image as black (Streaks, Simple Star, Sun Beams)
vec3 arm_glare_tap(sampler2D image, vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec3(0.0);
	return textureLod(image, uv, 0.0).rgb;
}

// Bloom: a coarser level brought up with a 3 x 3 tent of bilinear taps half a coarse
// texel apart (weights 1, 2, 1 per axis), as measured in Blender 5.2
vec3 arm_glare_tent(sampler2D coarse, vec2 uv) {
	vec2 o = 0.5 / vec2(textureSize(coarse, 0));
	vec3 sum = 4.0 * textureLod(coarse, uv, 0.0).rgb;
	sum += 2.0 * (textureLod(coarse, uv + vec2(o.x, 0.0), 0.0).rgb + textureLod(coarse, uv - vec2(o.x, 0.0), 0.0).rgb +
	              textureLod(coarse, uv + vec2(0.0, o.y), 0.0).rgb + textureLod(coarse, uv - vec2(0.0, o.y), 0.0).rgb);
	sum += textureLod(coarse, uv + o, 0.0).rgb + textureLod(coarse, uv - o, 0.0).rgb +
	       textureLod(coarse, uv + vec2(o.x, -o.y), 0.0).rgb + textureLod(coarse, uv + vec2(-o.x, o.y), 0.0).rgb;
	return sum / 16.0;
}

// The node's Saturation (HSV saturation, the largest channel kept), Tint and Strength
// on the scaled glare `g`: glare1.x strength, glare1.y saturation
vec3 arm_glare_finish(vec3 g, vec4 glare1, vec3 tint) {
	float v = max(g.r, max(g.g, g.b));
	float lo = min(g.r, min(g.g, g.b));
	if (v > 0.0 && v > lo) {
		// The distance of each channel from the largest one, scaled
		float s = (v - lo) / v;
		float scaled = clamp(s * glare1.y, 0.0, 1.0);
		g = v - (v - g) * (scaled / s);
	}
	return g * tint * glare1.x;
}
