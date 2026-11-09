package armory.renderpath.viewport.raster;

import iron.math.Mat4;
import iron.math.Vec4;

/**
	Temporal anti-aliasing, following Eevee's Samples setting (taa_samples).
	Each frame the camera projection is shifted by a sub-pixel jitter, taken from a
	Halton (2, 3) sequence of taa_samples positions. vpraster_taa_pass then blends
	the frame into the reprojected history with weight 1 / samples.
	taa_samples 1 turns it off. Higher counts, and 0 (unlimited in Blender), are
	capped at MAX_SAMPLES.
	The renderer calls begin() before drawing the scene and end() after it.
**/
class RasterTaa {

	public static inline var MAX_SAMPLES = 16;

	/** The unjittered view-projection of this frame and of the last one (for motion vectors and the sky). **/
	public static var vp = Mat4.identity();
	public static var prevVP = Mat4.identity();
	/** x: weight of this frame, yz: jitter in pixels (along NDC axes), w: filter size in pixels. **/
	public static var params = new Vec4(1, 0, 0, 1.5);
	/**
		The pixel filter's weight for each of the 3 x 3 taps, one vec4 per row (xyz).
		They depend only on this frame's jitter and filter size, so they are worked
		out here once per frame instead of per pixel in the shader (vpraster_taa_pass,
		link _vprasterTaaWeights). vec4 rows, because Direct3D pads each element of a
		float array to 16 bytes.
	**/
	public static var weights = new kha.arrays.Float32Array(12);

	static var unjitteredP = Mat4.identity();
	/** Frames drawn so far. The per-pixel noise (alpha cut-outs, soft shadows, dither) changes with it. **/
	public static var frame(default, null) = 0;

	/**
		The frame number for the shaders' per-pixel noise, kept small so it stays
		exact in a float. Soft shadows and the film's dither repeat every 64 frames.
	**/
	public static inline function noiseFrame(): Int {
		return frame % 64;
	}

	/** The frame number for noise with a longer period: alpha cut-outs and Sun Beams repeat every 1024 frames. **/
	public static inline function longNoiseFrame(): Int {
		return frame % 1024;
	}
	static var first = true;

	public static var enabled(get, never): Bool;
	static function get_enabled(): Bool {
		return RasterSettings.taaSamples != 1;
	}

	static function sampleCount(): Int {
		var n = RasterSettings.taaSamples;
		return (n <= 0 || n > MAX_SAMPLES) ? MAX_SAMPLES : n;
	}

	/** Called before drawing. Jitters the active camera for a target of `width` x `height` pixels. **/
	public static function begin(width: Float, height: Float) {
		var camera = iron.Scene.active.camera;
		vp.setFrom(camera.VP); // CameraObject.buildMatrix() has built it before the render path runs
		if (first) prevVP.setFrom(vp);
		if (!enabled) {
			params.set(1, 0, 0, RasterSettings.filterSize);
			setWeights(0, 0, RasterSettings.filterSize);
			return;
		}

		var n = sampleCount();
		var index = frame % n + 1; // starts at 1: Halton index 0 is the pixel corner
		var jx = halton(index, 2) - 0.5;
		var jy = halton(index, 3) - 0.5;

		// Shifts the image by (jx, jy) pixels in NDC
		unjitteredP.setFrom(camera.P);
		if (camera.P._23 != 0) { // Perspective: w = -z_view
			camera.P._20 -= 2 * jx / width;
			camera.P._21 -= 2 * jy / height;
		}
		else { // Orthographic: w = 1
			camera.P._30 += 2 * jx / width;
			camera.P._31 += 2 * jy / height;
		}
		camera.VP.multmats(camera.P, camera.V);
		params.set(first ? 1.0 : 1.0 / n, jx, jy, RasterSettings.filterSize);
		setWeights(jx, jy, RasterSettings.filterSize);
	}

	/**
		Sets the weights of the 3 x 3 taps for this frame's jitter (jx, jy) and the
		filter size, both in pixels. Each weight is Blender's pixel filter at the
		distance between the tap's sample and the pixel's centre.

		The jitter shifts the image by +(jx, jy) pixels. So the neighbour at offset
		(x, y) holds the scene as seen at (x - jx, y - jy) from this pixel's centre.

		Blender's pixel filter is a Blackman-Harris over the filter size. A Gaussian
		approximates it here. Rows follow NDC's y. Where texture rows run downwards
		(_InvY), the shader reads them mirrored.
	**/
	static function setWeights(jx: Float, jy: Float, filterSize: Float) {
		var scale = 1.5 / Math.max(filterSize, 0.01);
		for (y in -1...2) {
			for (x in -1...2) {
				var dx = (x - jx) * scale;
				var dy = (y - jy) * scale;
				weights[(y + 1) * 4 + (x + 1)] = Math.exp(-2.29 * (dx * dx + dy * dy));
			}
		}
	}

	/** Called after drawing the scene. Restores the unjittered camera and remembers this frame's matrix. **/
	public static function end() {
		var camera = iron.Scene.active.camera;
		if (enabled) {
			camera.P.setFrom(unjitteredP);
			camera.VP.multmats(camera.P, camera.V);
		}
		prevVP.setFrom(vp);
		frame++;
		first = false;
	}

	/** Drops the history. The renderer calls it on a scene switch, a window resize or a camera change. **/
	public static function reset() {
		first = true;
	}

	/** The Halton sequence's `index`-th value in `base`, in [0, 1). **/
	static function halton(index: Int, base: Int): Float {
		var result = 0.0;
		var fraction = 1.0;
		while (index > 0) {
			fraction /= base;
			result += fraction * (index % base);
			index = Std.int(index / base);
		}
		return result;
	}
}
