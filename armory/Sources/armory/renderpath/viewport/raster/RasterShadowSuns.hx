package armory.renderpath.viewport.raster;

import iron.Scene;
import iron.math.Mat4;
import iron.math.Vec4;

/**
	The shadow views of sun lights: orthographic views over the camera's depth range.

	With a perspective camera, a sun gets SUN_CASCADES slices that grow with
	distance. With an orthographic camera, it gets as many equal slices as keep the
	views smallest (slices()). Each view is fitted around a bounding sphere, so its
	size does not change when the camera turns. It is snapped to whole texels, so
	shadow edges stay still while the camera moves. Its texels are about one screen
	pixel at the view's nearest point (TEXEL_PER_PIXEL).

	A frame takes three steps (RasterShadows calls them):
	1. add(): a light asks for a sun's views. The depth range to cover is found here.
	2. fit(): each view gets its bounding sphere and asks the atlas for a tile.
	3. place(): once the tiles are known, each view is written, snapped to its texels.
**/
class RasterShadowSuns {

	static inline var SUN_CASCADES = 4; // sun views with a perspective camera
	/** A sun texel's size relative to a screen pixel at the view's nearest point. Fitted to match Eevee's hard shadow edges. **/
	static inline var TEXEL_PER_PIXEL = 1.0;
	/**
		The share of logarithmic splits with a perspective camera, the rest being
		uniform (see split()). Logarithmic splits give near slices the small views
		their texel size needs. The uniform share keeps the nearest slices from getting too thin.
	**/
	static inline var LOG_SPLIT_SHARE = 0.75;
	/** A bounding sphere's radius is rounded up to a power of 2^(1 / this), so a view's size changes less often. **/
	static inline var RADIUS_STEPS = 8;
	/** The smallest depth range of a view (metres), so dividing by it is safe when the slice is flat. **/
	static inline var MIN_DEPTH_RANGE = 1e-4;

	static var suns: Array<SunShadow> = []; // reused every frame; the first `sunCount` are this frame's
	static var sunCount = 0;
	/** Per view: its bounding sphere (centre, radius in w), kept from fit() to place(). **/
	public static var spheres = [for (_ in 0...RasterShadows.MAX_VIEWS) new Vec4()];
	/** Height of the lit image in pixels, for the views' texel size. **/
	public static var screenHeight = 1;

	static var corners = [for (_ in 0...8) new Vec4()];
	static var invVP = Mat4.identity();

	/** Starts a frame. Drops the previous frame's suns. **/
	public static function begin() {
		sunCount = 0;
	}

	/**
		Adds the views of a sun (see RasterShadows.addSun()). Finds the depth range
		they must cover and the light's basis. fit() and place() do the rest.
	**/
	public static function add(dx: Float, dy: Float, dz: Float): Int {
		var camera = Scene.active.camera;
		if (!RasterSettings.current.use_shadows || camera == null) return -1;
		var near = camera.data.raw.near_plane;
		var far = camera.data.raw.far_plane;

		// The depth range with something to shade: the meshes in front of the camera.
		// Also finds the shadow caster nearest to the light.
		var look = camera.lookWorld().normalize();
		var cx = camera.transform.worldx(), cy = camera.transform.worldy(), cz = camera.transform.worldz();
		var receiverNear = far, receiverFar = near;
		var casterMin = Math.POSITIVE_INFINITY;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible) continue;
			var t = mesh.transform;
			var x = t.worldx(), y = t.worldy(), z = t.worldz();
			var d = (x - cx) * look.x + (y - cy) * look.y + (z - cz) * look.z;
			var r = RasterShadowCasters.halfExtent(mesh, look.x, look.y, look.z);
			if (d - r < receiverNear) receiverNear = d - r;
			if (d + r > receiverFar) receiverFar = d + r;
			if (mesh.visibleShadow) {
				var along = x * dx + y * dy + z * dz - RasterShadowCasters.halfExtent(mesh, dx, dy, dz);
				if (along < casterMin) casterMin = along;
			}
		}
		var start = Math.max(near, receiverNear);
		var end = Math.min(far, receiverFar);
		if (end <= start) end = start + 1.0;

		var first = RasterShadowViews.reserve(slices(camera, end - start), RasterShadowViews.SUN_VIEW);
		if (first < 0) return -1;
		if (sunCount == suns.length) suns.push(new SunShadow());
		var sun = suns[sunCount++];
		sun.firstView = first;
		sun.direction.set(dx, dy, dz);
		sun.nearestCaster = casterMin;
		sun.rangeStart = start;
		sun.rangeEnd = end;
		// A sun's tiles run the other way along both axes: the same basis, turned half a turn about the light
		RasterShadowViews.lightBasis(dx, dy, dz, sun.right, sun.up);
		sun.right.mult(-1);
		sun.up.mult(-1);
		return first;
	}

	/**
		The number of views of a sun over `depth` metres of the camera's view.

		A perspective camera gets SUN_CASCADES views, each at the texel size its
		nearest point needs.

		An orthographic camera's pixels are the same size at every depth. Its view
		is a W x H x depth box. Cut into n equal slices, the slices' bounding spheres
		have n (W^2 + H^2) / 4 + depth^2 / (4 n) square metres in all. That is least
		at n = depth / sqrt(W^2 + H^2): one view for a shallow box, more as it gets deeper.
	**/
	static function slices(camera: iron.object.CameraObject, depth: Float): Int {
		if (camera.P._23 != 0) return SUN_CASCADES;
		var w = 2 / camera.P._00, h = 2 / camera.P._11;
		var n = Math.round(depth / Math.sqrt(w * w + h * h));
		return Std.int(Math.max(1, Math.min(n, SUN_CASCADES)));
	}

	/**
		Sizes the views of every sun, for a lit image `height` pixels high. Each view
		asks the atlas for at most `pool` texels (RasterShadowAtlas.needs).
	**/
	public static function fit(height: Int, pool: Int) {
		screenHeight = height;
		for (i in 0...sunCount) fitSun(suns[i], pool);
	}

	/** Writes the views of every sun for their tiles. Runs after fit() and RasterShadowAtlas.pack(). **/
	public static function place() {
		for (i in 0...sunCount) placeSun(suns[i]);
	}

	/**
		Sizes a sun's views. Splits the camera's depth range, fits a bounding sphere
		around each slice, and asks for a tile whose texels are TEXEL_PER_PIXEL screen
		pixels at the slice's nearest point (at most `pool` texels).
	**/
	static function fitSun(sun: SunShadow, pool: Int) {
		var first = sun.firstView;
		var camera = Scene.active.camera;
		var near = camera.data.raw.near_plane;
		var far = camera.data.raw.far_plane;
		var start = sun.rangeStart, end = sun.rangeEnd;

		// Rays through the screen corners, as points on the near and far planes
		invVP.getInverse(camera.VP);
		for (i in 0...4) {
			var sx = (i & 1) == 0 ? -1.0 : 1.0;
			var sy = (i & 2) == 0 ? -1.0 : 1.0;
			corners[i].set(sx, sy, -1, 1).applyproj(invVP);
			corners[i + 4].set(sx, sy, 1, 1).applyproj(invVP);
		}

		// A screen pixel's size in metres: at distance 1 for a perspective camera, anywhere for an orthographic one
		var perspective = camera.P._23 != 0;
		var pixel = 2.0 / (camera.P._11 * screenHeight);
		var count = RasterShadowViews.groups[first];
		var lambda = perspective ? LOG_SPLIT_SHARE : 0.0;
		for (c in 0...count) {
			var d0 = split(start, end, c / count, lambda);
			var d1 = split(start, end, (c + 1) / count, lambda);
			var t0 = (d0 - near) / (far - near);
			var t1 = (d1 - near) / (far - near);

			// Bounding sphere of the slice
			var mx = 0.0, my = 0.0, mz = 0.0;
			for (i in 0...4) for (k in 0...2) {
				var t = k == 0 ? t0 : t1;
				mx += lerp(corners[i].x, corners[i + 4].x, t);
				my += lerp(corners[i].y, corners[i + 4].y, t);
				mz += lerp(corners[i].z, corners[i + 4].z, t);
			}
			mx /= 8; my /= 8; mz /= 8;
			var radius = 0.0;
			for (i in 0...4) for (k in 0...2) {
				var t = k == 0 ? t0 : t1;
				var ex = lerp(corners[i].x, corners[i + 4].x, t) - mx;
				var ey = lerp(corners[i].y, corners[i + 4].y, t) - my;
				var ez = lerp(corners[i].z, corners[i + 4].z, t) - mz;
				radius = Math.max(radius, Math.sqrt(ex * ex + ey * ey + ez * ez));
			}
			radius = Math.pow(2, Math.ceil(Math.log(radius) / Math.log(2) * RADIUS_STEPS) / RADIUS_STEPS);
			spheres[first + c].set(mx, my, mz, radius);

			var texel = TEXEL_PER_PIXEL * pixel * (perspective ? Math.max(d0, near) : 1.0);
			RasterShadowAtlas.needs[first + c] = Math.min(2 * radius / texel, pool);
		}
	}

	/** Writes a sun's views for their tiles, snapped to whole texels. **/
	static function placeSun(sun: SunShadow) {
		var dx = sun.direction.x, dy = sun.direction.y, dz = sun.direction.z;
		var first = sun.firstView;
		var r = sun.right, u = sun.up;
		for (c in 0...RasterShadowViews.groups[first]) {
			var view = first + c;
			var tile = Math.max(RasterShadowAtlas.tiles[view][2], 1);
			var sphere = spheres[view];
			var radius = sphere.w;
			var texel = 2 * radius / tile;
			var centerRight = Math.floor((sphere.x * r.x + sphere.y * r.y + sphere.z * r.z) / texel) * texel;
			var centerUp = Math.floor((sphere.x * u.x + sphere.y * u.y + sphere.z * u.z) / texel) * texel;
			var centerDepth = sphere.x * dx + sphere.y * dy + sphere.z * dz;
			var zmin = Math.min(sun.nearestCaster, centerDepth - radius);
			var zmax = centerDepth + radius;
			var zrange = Math.max(zmax - zmin, MIN_DEPTH_RANGE);

			var o = RasterShadowViews.offset(view);
			var s = 1.0 / (2 * radius);
			RasterShadowViews.setRow(o + RasterShadowViews.ROW_U, r.x * s, r.y * s, r.z * s, 0.5 - centerRight * s);
			RasterShadowViews.setRow(o + RasterShadowViews.ROW_V, -u.x * s, -u.y * s, -u.z * s, 0.5 + centerUp * s);
			RasterShadowViews.setRow(o + RasterShadowViews.ROW_DEPTH, dx / zrange, dy / zrange, dz / zrange, -zmin / zrange);
			RasterShadowViews.setRow(o + RasterShadowViews.ROW_W, 0, 0, 0, 1);
			RasterShadowViews.setRow(o + RasterShadowViews.ROW_EXTRA, s, 0, zrange, 0);
		}
	}

	static inline function lerp(a: Float, b: Float, t: Float): Float {
		return a + (b - a) * t;
	}

	/** The split at fraction `f` of [start, end]: a blend of logarithmic and uniform splits, `lambda` logarithmic. **/
	static function split(start: Float, end: Float, f: Float, lambda: Float): Float {
		var uniform = start + (end - start) * f;
		if (lambda <= 0 || start <= 0) return uniform;
		return lambda * start * Math.pow(end / start, f) + (1 - lambda) * uniform;
	}
}

/** One sun's shadow data, kept from add() to place(). The instances are reused every frame. **/
private class SunShadow {
	public var firstView = 0; // the index of its first view
	public var direction = new Vec4(); // where the light travels (unit vector)
	public var right = new Vec4(); // the light's basis: a tile's u runs along `right`, and its v against `up`
	public var up = new Vec4();
	public var nearestCaster = 0.0; // the shadow caster nearest to the light, in metres along `direction`
	public var rangeStart = 0.0; // the camera depth range to cover (metres)
	public var rangeEnd = 0.0;

	public function new() {}
}
