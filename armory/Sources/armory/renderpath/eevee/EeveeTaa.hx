package armory.renderpath.eevee;

import iron.math.Mat4;
import iron.math.Vec4;

/**
	Temporal anti-aliasing for Eevee's taa_samples: the camera projection is
	jittered by a Halton (2, 3) sequence of taa_samples positions (at most
	MAX_SAMPLES, 0 = unlimited in Blender) and eevee_taa_pass blends each frame
	into the reprojected history with weight 1 / samples. taa_samples 1 = off.
**/
class EeveeTaa {

	public static inline var MAX_SAMPLES = 16;

	/** Unjittered view-projection of this frame and the last one (velocity, sky). **/
	public static var vp = Mat4.identity();
	public static var prevVP = Mat4.identity();
	/** x: weight of this frame, yz: jitter in pixels (NDC axes), w: filter size in pixels. **/
	public static var params = new Vec4(1, 0, 0, 1.5);

	static var unjitteredP = Mat4.identity();
	/** Frames drawn so far: the per-pixel noise (alpha cut-outs, soft shadows, dither) moves with it. **/
	public static var frame(default, null) = 0;
	static var first = true;

	public static var enabled(get, never): Bool;
	static function get_enabled(): Bool {
		return EeveeSettings.taaSamples != 1;
	}

	static function sampleCount(): Int {
		var n = EeveeSettings.taaSamples;
		return (n <= 0 || n > MAX_SAMPLES) ? MAX_SAMPLES : n;
	}

	/** Call before drawing: jitters the active camera for a target of width x height pixels. **/
	public static function begin(width: Float, height: Float) {
		var camera = iron.Scene.active.camera;
		vp.setFrom(camera.VP); // built by CameraObject.buildMatrix() before the render path runs
		if (first) prevVP.setFrom(vp);
		if (!enabled) {
			params.set(1, 0, 0, EeveeSettings.filterSize);
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
		params.set(first ? 1.0 : 1.0 / n, jx, jy, EeveeSettings.filterSize);
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

	/** Drops the history, e.g. when the scene changes. **/
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
