package armory.renderpath.viewport.raster;

import iron.math.Mat4;
import iron.math.Vec4;

/**
	Temporal anti-aliasing for Eevee's taa_samples: the camera projection is
	jittered by a Halton (2, 3) sequence of taa_samples positions (at most
	MAX_SAMPLES, 0 = unlimited in Blender) and vpraster_taa_pass blends each frame
	into the reprojected history with weight 1 / samples. taa_samples 1 = off.
**/
class RasterTaa {

	public static inline var MAX_SAMPLES = 16;

	/** Unjittered view-projection of this frame and the last one (velocity, sky). **/
	public static var vp = Mat4.identity();
	public static var prevVP = Mat4.identity();
	/** x: weight of this frame, yz: jitter in pixels (NDC axes), w: filter size in pixels. **/
	public static var params = new Vec4(1, 0, 0, 1.5);
	/**
		The pixel filter's weight of each of the 3 x 3 taps, one vec4 per row (xyz), for
		this frame's jitter and filter size: the same for every pixel, so worked out here
		once per frame instead of in the shader (vpraster_taa_pass, link
		_vprasterTaaWeights). vec4s, as Direct3D pads every element of a float array to one.
	**/
	public static var weights = new kha.arrays.Float32Array(12);

	static var unjitteredP = Mat4.identity();
	/** Frames drawn so far: the per-pixel noise (alpha cut-outs, soft shadows, dither) moves with it. **/
	public static var frame(default, null) = 0;

	/**
		The frame number given to the shaders' per-pixel noise, kept small so it stays
		exact in a float. Soft shadows and the film's dither repeat every 64 frames,
		alpha cut-outs every 1024.
	**/
	public static inline function noiseFrame(): Int {
		return frame % 64;
	}

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

	/** Call before drawing: jitters the active camera for a target of width x height pixels. **/
	public static function begin(width: Float, height: Float) {
		var camera = iron.Scene.active.camera;
		vp.setFrom(camera.VP); // built by CameraObject.buildMatrix() before the render path runs
		if (first) prevVP.setFrom(vp);
		if (!enabled) {
			params.set(1, 0, 0, RasterSettings.filterSize);
			setWeights(0, 0, RasterSettings.filterSize);
			return;
		}

		var n = sampleCount();
		var index = frame % n + 1; // Halton index 0 is the pixel corner
		var jx = halton(index, 2) - 0.5;
		var jy = halton(index, 3) - 0.5;

		// Shift NDC by (jx, jy) pixels
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
		Blender's pixel filter (a Blackman-Harris, approximated by a Gaussian over the
		filter size) at each tap's distance from where this pixel's sample was taken.
		The jitter moves the image by (jx, jy) pixels, so each pixel shows the scene
		from (jx, jy) before its centre: the tap at (x, y) was sampled at (x - jx, y - jy).
		(Taken as + until Nov 2026, which widened every edge by half a pixel.) A true
		Blackman-Harris narrowed edges another 0.06 px but let soft-shadow noise through
		(the flicker check failed). Rows follow NDC's y; where texture rows run downwards
		(_InvY) the shader reads them mirrored.
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

	/** Call after drawing the scene: restores the camera and remembers this frame's matrix. **/
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

	/** Drops the history: scene change, window resize, camera change (RenderPathViewportRaster). **/
	public static function reset() {
		first = true;
	}

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
