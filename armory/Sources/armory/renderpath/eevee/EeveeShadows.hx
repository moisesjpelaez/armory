package armory.renderpath.eevee;

import kha.arrays.Float32Array;
import iron.RenderPath;
import iron.Scene;
import iron.math.Mat4;
import iron.math.Vec4;
import iron.object.MeshObject;

/**
	Shadow maps for the Eevee renderer. All shadow views share one depth atlas
	(size from Eevee's shadow_pool_size). Each frame the lights request views,
	then render() draws the shadow casters into each view's tile.

	Sun lights get SUN_CASCADES views covering the camera's depth range in
	growing slices. Each slice is fitted with a bounding sphere (its size does
	not change when the camera turns) and snapped to whole texels, so shadow
	edges stay still while the camera moves.

	The shader side is glsl_rewrite.SHADOWS: per view, three rows mapping a world
	position to tile u, v (v down) and depth (0..1), and the tile's place in the
	atlas.
**/
class EeveeShadows {

	public static inline var MAX_VIEWS = 16; // glsl_rewrite.MAX_SHADOW_VIEWS
	public static inline var SUN_CASCADES = 4; // glsl_rewrite.SUN_CASCADES
	static inline var VIEW_VEC4S = 4;
	static inline var CONTEXT = "eevee_shadow"; // materials.SHADOW_CONTEXT
	static inline var TARGET = "eevee_shadow_atlas";
	static inline var MIN_ATLAS = 1024;
	static inline var MAX_ATLAS = 4096;

	public static var views = new Float32Array(MAX_VIEWS * VIEW_VEC4S * 4);
	public static var info = new Vec4();
	/** Clip matrix of the tile being drawn (link _eeveeShadowVP). **/
	public static var viewProjection = Mat4.identity();
	public static var atlas(get, never): kha.Image;

	static var viewCount = 0;
	static var suns: Array<Vec4> = []; // light direction (xyz), first view (w)
	static var sunCount = 0;
	static var clipMatrices = [for (_ in 0...MAX_VIEWS) Mat4.identity()];
	static var atlasSize = 0;
	static var target: iron.RenderPath.RenderTarget = null;
	static var savedPrevMatrix = Mat4.identity();

	static var corners = [for (_ in 0...8) new Vec4()];
	static var invVP = Mat4.identity();

	/** Starts a frame: drops the previous frame's views. **/
	public static function begin() {
		viewCount = 0;
		sunCount = 0;
	}

	/**
		Adds the cascades of a sun travelling along (dx, dy, dz), normalised.
		Returns the first view index, or -1 when shadows are off or the atlas is full.
	**/
	public static function addSun(dx: Float, dy: Float, dz: Float): Int {
		if (!EeveeSettings.useShadows || viewCount + SUN_CASCADES > MAX_VIEWS) return -1;
		var camera = Scene.active.camera;
		if (camera == null) return -1;
		var first = viewCount;
		viewCount += SUN_CASCADES;
		if (sunCount == suns.length) suns.push(new Vec4());
		suns[sunCount++].set(dx, dy, dz, first);
		return first;
	}

	static function get_atlas(): kha.Image {
		return target != null ? target.image : null;
	}

	/** Draws every view's shadow casters into the atlas (before the main pass). **/
	public static function render(path: RenderPath) {
		ensureAtlas(path);
		info.set(1.0 / atlasSize, 0, 0, 0);
		if (viewCount == 0) return;
		// Fitted once every light has asked: the tile size depends on the view count
		for (i in 0...sunCount) fitSun(Std.int(suns[i].w), suns[i].x, suns[i].y, suns[i].z);

		path.setTarget(TARGET);
		var g = path.currentG;
		g.clear(kha.Color.White, 1.0); // depth 1 = nothing in the way
		var tile = tileSize();
		for (view in 0...viewCount) {
			var rect = tileRect(view, tile);
			g.viewport(rect[0], rect[1], tile, tile);
			viewProjection.setFrom(clipMatrices[view]);
			drawCasters(g, view);
		}
	}

	static function drawCasters(g: kha.graphics4.Graphics, view: Int) {
		var o = view * VIEW_VEC4S * 4;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible || !mesh.visibleShadow) continue;
			if (!inView(mesh, o)) continue;
			// MeshObject.render() culls against the camera and records the
			// motion matrix for velocity; neither applies to a shadow view.
			var culling = mesh.frustumCulling;
			mesh.frustumCulling = false;
			#if arm_veloc savedPrevMatrix.setFrom(mesh.prevMatrix); #end
			mesh.render(g, CONTEXT, []);
			#if arm_veloc mesh.prevMatrix.setFrom(savedPrevMatrix); #end
			mesh.frustumCulling = culling;
		}
	}

	/** Bounding sphere of the mesh against the view's tile and depth range. **/
	static function inView(mesh: MeshObject, o: Int): Bool {
		var t = mesh.transform;
		var x = t.worldx(), y = t.worldy(), z = t.worldz();
		var r = t.radius;
		for (row in 0...2) {
			var i = o + row * 4;
			var scale = Math.sqrt(views[i] * views[i] + views[i + 1] * views[i + 1] + views[i + 2] * views[i + 2]);
			var c = views[i] * x + views[i + 1] * y + views[i + 2] * z + views[i + 3];
			if (c + r * scale < 0 || c - r * scale > 1) return false;
		}
		var i = o + 8;
		var scale = Math.sqrt(views[i] * views[i] + views[i + 1] * views[i + 1] + views[i + 2] * views[i + 2]);
		var depth = views[i] * x + views[i + 1] * y + views[i + 2] * z + views[i + 3];
		return depth - r * scale <= 1;
	}

	static function fitSun(first: Int, dx: Float, dy: Float, dz: Float) {
		var camera = Scene.active.camera;
		var near = camera.data.raw.near_plane;
		var far = camera.data.raw.far_plane;

		// Light basis: d travels with the light, right/up span the tiles
		var ux = 0.0, uy = 0.0, uz = 1.0;
		if (Math.abs(dz) > 0.99) { ux = 0.0; uy = 1.0; uz = 0.0; }
		var rx = uy * dz - uz * dy, ry = uz * dx - ux * dz, rz = ux * dy - uy * dx;
		var rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
		rx /= rl; ry /= rl; rz /= rl;
		var upx = dy * rz - dz * ry, upy = dz * rx - dx * rz, upz = dx * ry - dy * rx;

		// Depth range with something to shade: the meshes in front of the camera
		var look = camera.lookWorld().normalize();
		var cx = camera.transform.worldx(), cy = camera.transform.worldy(), cz = camera.transform.worldz();
		var receiverNear = far, receiverFar = near;
		var casterMin = Math.POSITIVE_INFINITY;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible) continue;
			var t = mesh.transform;
			var x = t.worldx(), y = t.worldy(), z = t.worldz(), r = t.radius;
			var d = (x - cx) * look.x + (y - cy) * look.y + (z - cz) * look.z;
			if (d - r < receiverNear) receiverNear = d - r;
			if (d + r > receiverFar) receiverFar = d + r;
			if (mesh.visibleShadow) {
				var along = x * dx + y * dy + z * dz - r;
				if (along < casterMin) casterMin = along;
			}
		}
		var start = Math.max(near, receiverNear);
		var end = Math.min(far, receiverFar);
		if (end <= start) end = start + 1.0;

		// Rays through the screen corners: points at view distance `near` and `far`
		invVP.getInverse(camera.VP);
		for (i in 0...4) {
			var sx = (i & 1) == 0 ? -1.0 : 1.0;
			var sy = (i & 2) == 0 ? -1.0 : 1.0;
			corners[i].set(sx, sy, -1, 1).applyproj(invVP);
			corners[i + 4].set(sx, sy, 1, 1).applyproj(invVP);
		}

		var perspective = camera.P._23 != 0;
		var lambda = perspective ? 0.75 : 0.0; // logarithmic share of the split scheme
		var tile = tileSize();
		for (c in 0...SUN_CASCADES) {
			var d0 = split(start, end, c / SUN_CASCADES, lambda);
			var d1 = split(start, end, (c + 1) / SUN_CASCADES, lambda);
			var t0 = (d0 - near) / (far - near);
			var t1 = (d1 - near) / (far - near);

			// Bounding sphere of the slice
			var mx = 0.0, my = 0.0, mz = 0.0;
			for (i in 0...4) for (t in [t0, t1]) {
				mx += lerp(corners[i].x, corners[i + 4].x, t);
				my += lerp(corners[i].y, corners[i + 4].y, t);
				mz += lerp(corners[i].z, corners[i + 4].z, t);
			}
			mx /= 8; my /= 8; mz /= 8;
			var radius = 0.0;
			for (i in 0...4) for (t in [t0, t1]) {
				var ex = lerp(corners[i].x, corners[i + 4].x, t) - mx;
				var ey = lerp(corners[i].y, corners[i + 4].y, t) - my;
				var ez = lerp(corners[i].z, corners[i + 4].z, t) - mz;
				radius = Math.max(radius, Math.sqrt(ex * ex + ey * ey + ez * ez));
			}
			radius = Math.pow(2, Math.ceil(Math.log(radius) / Math.log(2) * 8) / 8); // fewer size changes

			// Snap the centre to whole texels
			var texel = 2 * radius / tile;
			var centerRight = Math.floor((mx * rx + my * ry + mz * rz) / texel) * texel;
			var centerUp = Math.floor((mx * upx + my * upy + mz * upz) / texel) * texel;
			var centerDepth = mx * dx + my * dy + mz * dz;
			var zmin = Math.min(casterMin, centerDepth - radius);
			var zmax = centerDepth + radius;
			var zrange = Math.max(zmax - zmin, 1e-4);

			var o = (first + c) * VIEW_VEC4S * 4;
			var s = 1.0 / (2 * radius);
			setRow(o, rx * s, ry * s, rz * s, 0.5 - centerRight * s);
			setRow(o + 4, -upx * s, -upy * s, -upz * s, 0.5 + centerUp * s);
			setRow(o + 8, dx / zrange, dy / zrange, dz / zrange, -zmin / zrange);
			var rect = tileRect(first + c, tile);
			setRow(o + 12, rect[0] / atlasSize, rect[1] / atlasSize, tile / atlasSize, tile / atlasSize);
			setClipMatrix(first + c, o);
		}
	}

	/** World -> clip for drawing into the tile: x = 2u - 1, y = 1 - 2v, z = 2 depth - 1. **/
	static function setClipMatrix(view: Int, o: Int) {
		var flip = kha.Image.renderTargetsInvertedY() ? -1.0 : 1.0;
		var v = views;
		clipMatrices[view] = new Mat4(
			2 * v[o], 2 * v[o + 1], 2 * v[o + 2], 2 * v[o + 3] - 1,
			-2 * flip * v[o + 4], -2 * flip * v[o + 5], -2 * flip * v[o + 6], flip * (1 - 2 * v[o + 7]),
			2 * v[o + 8], 2 * v[o + 9], 2 * v[o + 10], 2 * v[o + 11] - 1,
			0, 0, 0, 1
		);
	}

	static inline function setRow(o: Int, x: Float, y: Float, z: Float, w: Float) {
		views[o] = x; views[o + 1] = y; views[o + 2] = z; views[o + 3] = w;
	}

	static inline function lerp(a: Float, b: Float, t: Float): Float {
		return a + (b - a) * t;
	}

	/** Blend of logarithmic and uniform splits of [start, end]. **/
	static function split(start: Float, end: Float, f: Float, lambda: Float): Float {
		var uniform = start + (end - start) * f;
		if (lambda <= 0 || start <= 0) return uniform;
		return lambda * start * Math.pow(end / start, f) + (1 - lambda) * uniform;
	}

	/** Tiles in a grid: 2x2 for up to 4 views, 4x4 for more. **/
	static function tileSize(): Int {
		return viewCount <= 4 ? Std.int(atlasSize / 2) : Std.int(atlasSize / 4);
	}

	static function tileRect(view: Int, tile: Int): Array<Int> {
		var columns = Std.int(atlasSize / tile);
		return [(view % columns) * tile, Std.int(view / columns) * tile];
	}

	/** Atlas side: the largest power of two whose depth + R32 texels fit Eevee's pool size. **/
	static function wantedSize(): Int {
		var bytes = EeveeSettings.shadowPoolSize * 1024.0 * 1024.0;
		var size = MIN_ATLAS;
		while (size * 2 <= MAX_ATLAS && (size * 2.0) * (size * 2.0) * 8 <= bytes) size *= 2;
		return size;
	}

	static function ensureAtlas(path: RenderPath) {
		var size = wantedSize();
		if (size == atlasSize && target != null) return;
		if (target != null) target.image.unload();
		var raw = new iron.RenderPath.RenderTargetRaw();
		raw.name = TARGET;
		raw.width = size;
		raw.height = size;
		raw.format = "R32";
		target = new iron.RenderPath.RenderTarget(raw);
		target.image = kha.Image.createRenderTarget(size, size, kha.graphics4.TextureFormat.A32,
			kha.graphics4.DepthStencilFormat.DepthOnly);
		path.renderTargets.set(TARGET, target);
		atlasSize = size;
	}
}
