// Helpers shared by the passes of the compositor's Glare node (Shaders/viewport_glare_*,
// drawn by ViewportCompositor). The Glare node runs in the compositor, on the linear
// image before temporal anti-aliasing. renderpath.py copies this file next to the
// compiled shaders and recompiles the passes when it changes.

// A texture read that counts outside the image as black (Streaks, Simple Star, Sun Beams)
vec3 arm_glare_tap(sampler2D image, vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec3(0.0);
	return textureLod(image, uv, 0.0).rgb;
}

// Bloom: reads a coarser level at this finer pixel, as Blender does. A 3 x 3 tent of
// bilinear reads, half a coarse texel apart, weighted 1, 2, 1 per axis.
vec3 arm_glare_tent(sampler2D coarse, vec2 uv) {
	vec2 o = 0.5 / vec2(textureSize(coarse, 0));
	vec3 sum = 4.0 * textureLod(coarse, uv, 0.0).rgb;
	sum += 2.0 * (textureLod(coarse, uv + vec2(o.x, 0.0), 0.0).rgb + textureLod(coarse, uv - vec2(o.x, 0.0), 0.0).rgb +
	              textureLod(coarse, uv + vec2(0.0, o.y), 0.0).rgb + textureLod(coarse, uv - vec2(0.0, o.y), 0.0).rgb);
	sum += textureLod(coarse, uv + o, 0.0).rgb + textureLod(coarse, uv - o, 0.0).rgb +
	       textureLod(coarse, uv + vec2(o.x, -o.y), 0.0).rgb + textureLod(coarse, uv + vec2(-o.x, o.y), 0.0).rgb;
	return sum / 16.0;
}

// Applies the node's Saturation, Tint and Strength to the glare `g`. Saturation scales
// the HSV saturation and keeps the largest channel.
vec3 arm_glare_finish(vec3 g, float strength, float saturation, vec3 tint) {
	float v = max(g.r, max(g.g, g.b));
	float lo = min(g.r, min(g.g, g.b));
	if (v > 0.0 && v > lo) {
		// Scale each channel's distance from the largest one
		float s = (v - lo) / v;
		float scaled = clamp(s * saturation, 0.0, 1.0);
		g = v - (v - g) * (scaled / s);
	}
	return g * tint * strength;
}
