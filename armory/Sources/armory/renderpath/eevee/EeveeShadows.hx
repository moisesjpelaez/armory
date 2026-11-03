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

	Sun lights get SUN_CASCADES orthographic views covering the camera's depth
	range in growing slices. Each slice is fitted with a bounding sphere (its
	size does not change when the camera turns) and snapped to whole texels, so
	shadow edges stay still while the camera moves. Spot lights get one
	perspective view over their cone, point and area lights the six faces of a
	cube (slightly widened so filtering never runs off a face).

	The shader side is Shaders/eevee/eevee_lights.glsl. Per view, VIEW_VEC4S vec4:
	  0, 1: u and v numerators (tile 0..1, v down), 2: linear depth (0..1),
	  3: the divisor w (sun: 1), 4: the tile in the atlas (x, y, width, height),
	  5: tile uv per metre at w = 1, near distance (m), depth range (m), perspective
**/
class EeveeShadows {

	public static inline var MAX_VIEWS = 32; // lighting.DEFINES ARM_MAX_SHADOW_VIEWS
	public static inline var SUN_CASCADES = 4; // lighting.DEFINES ARM_SUN_CASCADES
	static inline var VIEW_VEC4S = 6; // lighting.DEFINES ARM_SHADOW_VIEW_VEC4S
	static inline var CONTEXT = "eevee_shadow"; // materials.SHADOW_CONTEXT
	static inline var TARGET = "eevee_shadow_atlas";
	static inline var MIN_ATLAS = 1024;
	static inline var MAX_ATLAS = 4096;
	static inline var CUBE_WIDEN = 1.1; // tan of a cube face's half angle (45 degrees + margin)
	static inline var LOCAL_NEAR = 0.05;
	static inline var LOCAL_FAR = 100.0; // without an influence radius

	public static var views = new Float32Array(MAX_VIEWS * VIEW_VEC4S * 4);
	public static var info = new Vec4();
	/** Clip matrix and linear depth row of the tile being drawn (links _eeveeShadowVP, _eeveeShadowDepth). **/
	public static var viewProjection = Mat4.identity();
	public static var depthRow = new Vec4();
	public static var atlas(get, never): kha.Image;

	// Measured on Eevee (phase 3.0): soft shadow width relative to the physical
	// penumbra for shadow_step_count 1, 2, 3, 4, 6, 8, 12, 16 (constant above 16).
	// Sun lights; local lights measured 1.10 at 6 steps and 1.00 at 16.
	static var STEP_COUNTS = [1, 2, 3, 4, 6, 8, 12, 16];
	static var STEP_WIDTHS = [0.19, 0.33, 0.47, 0.57, 0.70, 0.77, 0.85, 0.88];
	static var frame = 0;

	static var viewCount = 0;
	static var suns: Array<Vec4> = []; // light direction (xyz), first view (w)
	static var sunCount = 0;
	static var localCount = 0; // local light views this frame
	static var clipMatrices = [for (_ in 0...MAX_VIEWS) Mat4.identity()];
	static var tiles = [for (_ in 0...MAX_VIEWS) [0, 0, 0]]; // x, y, size in texels
	static inline var SUN_VIEW = 0;
	static inline var SPOT_VIEW = 1;
	static inline var CUBE_VIEW = 2;
	static var viewKinds = [for (_ in 0...MAX_VIEWS) SUN_VIEW];
	// The tile layout depends only on the views' kinds and the atlas size: kept until they change
	static var layoutKinds = [for (_ in 0...MAX_VIEWS) -1];
	static var layoutCount = -1;
	static var layoutAtlas = 0;
	// Cube face directions (x, y, z per face)
	static var CUBE_FACES = [1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0];
	static var NO_BIND_PARAMS: Array<String> = [];
	static var atlasSize = 0;
	static var target: iron.RenderPath.RenderTarget = null;
	static var savedPrevMatrix = Mat4.identity();

	static var corners = [for (_ in 0...8) new Vec4()];
	static var invVP = Mat4.identity();

	/** Starts a frame: drops the previous frame's views. **/
	public static function begin() {
		viewCount = 0;
		sunCount = 0;
		localCount = 0;
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
		for (i in 0...SUN_CASCADES) viewKinds[first + i] = SUN_VIEW;
		if (sunCount == suns.length) suns.push(new Vec4());
		suns[sunCount++].set(dx, dy, dz, first);
		return first;
	}

	/**
		Adds the views of a spot (one view over its cone, `spotSize` full angle) or a
		point/area light (six cube faces) at (px, py, pz), shining along (dx, dy, dz).
		`range` is the light's influence radius (0 = none). Returns the first view.
	**/
	public static function addLocal(spot: Bool, px: Float, py: Float, pz: Float,
			dx: Float, dy: Float, dz: Float, spotSize: Float, range: Float): Int {
		var count = spot ? 1 : 6;
		if (!EeveeSettings.useShadows || viewCount + count > MAX_VIEWS) return -1;
		var first = viewCount;
		viewCount += count;
		localCount += count;
		for (i in 0...count) viewKinds[first + i] = spot ? SPOT_VIEW : CUBE_VIEW;
		var far = range > 0 ? range : LOCAL_FAR;
		if (spot) {
			var halfTan = Math.tan(Math.min(spotSize * 0.5 + 0.1, 1.45));
			setPerspective(first, px, py, pz, dx, dy, dz, halfTan, far);
		}
		else {
			for (i in 0...6) setPerspective(first + i, px, py, pz, CUBE_FACES[i * 3], CUBE_FACES[i * 3 + 1], CUBE_FACES[i * 3 + 2], CUBE_WIDEN, far);
		}
		return first;
	}

	static function get_atlas(): kha.Image {
		return target != null ? target.image : null;
	}

	/** Draws every view's shadow casters into the atlas (before the main pass). **/
	public static function render(path: RenderPath) {
		ensureAtlas(path);
		frame = (frame + 1) % 64;
		info.set(1.0 / atlasSize, penumbraScale(EeveeSettings.shadowStepCount), frame,
			penumbraScaleLocal(EeveeSettings.shadowStepCount));
		if (viewCount == 0) return;
		if (layoutChanged()) allocateTiles();
		// Suns are fitted once every light has asked: their texel snapping needs the tile size
		for (i in 0...sunCount) fitSun(Std.int(suns[i].w), suns[i].x, suns[i].y, suns[i].z);
		for (view in 0...viewCount) {
			var o = view * VIEW_VEC4S * 4 + 16;
			var t = tiles[view];
			setRow(o, t[0] / atlasSize, t[1] / atlasSize, t[2] / atlasSize, t[2] / atlasSize);
			setClipMatrix(view);
		}

		path.setTarget(TARGET);
		var g = path.currentG;
		g.clear(kha.Color.White, 1.0); // depth 1 = nothing in the way
		for (view in 0...viewCount) {
			var t = tiles[view];
			g.viewport(t[0], t[1], t[2], t[2]);
			viewProjection.setFrom(clipMatrices[view]);
			var o = view * VIEW_VEC4S * 4 + 8;
			depthRow.set(views[o], views[o + 1], views[o + 2], views[o + 3]);
			drawCasters(g, view);
		}
	}

	static function layoutChanged(): Bool {
		var changed = viewCount != layoutCount || atlasSize != layoutAtlas;
		for (v in 0...viewCount) if (viewKinds[v] != layoutKinds[v]) changed = true;
		if (!changed) return false;
		layoutCount = viewCount;
		layoutAtlas = atlasSize;
		for (v in 0...viewCount) layoutKinds[v] = viewKinds[v];
		return true;
	}

	/**
		Quadtree placement (atlas side fractions): sun cascades 1/2 (1/4 when local
		lights share the atlas), spot lights 1/4 (one view), cube faces 1/8. Runs
		only when the views' kinds or the atlas size change (layoutChanged()).
	**/
	static function allocateTiles() {
		var sunTile = Std.int(atlasSize / (localCount > 0 ? 4 : 2));
		var localTile = Std.int(atlasSize / 8);
		var free: Array<Array<Int>> = [[0, 0, atlasSize]];
		// Largest first so the quadtree packs without gaps
		var order = [for (v in 0...viewCount) v];
		order.sort(function(a, b) return viewSize(b, sunTile, localTile) - viewSize(a, sunTile, localTile));
		for (v in order) {
			var size = viewSize(v, sunTile, localTile);
			// Smallest free square that fits, split down to the wanted size
			var best = -1;
			for (i in 0...free.length) if (free[i][2] >= size && (best < 0 || free[i][2] < free[best][2])) best = i;
			if (best < 0) { tiles[v][2] = 0; continue; }
			var node = free.splice(best, 1)[0];
			while (node[2] > size) {
				var h = Std.int(node[2] / 2);
				free.push([node[0] + h, node[1], h]);
				free.push([node[0], node[1] + h, h]);
				free.push([node[0] + h, node[1] + h, h]);
				node = [node[0], node[1], h];
			}
			tiles[v][0] = node[0];
			tiles[v][1] = node[1];
			tiles[v][2] = node[2];
		}
	}

	static function viewSize(view: Int, sunTile: Int, localTile: Int): Int {
		return switch (viewKinds[view]) {
			case SUN_VIEW: sunTile;
			case SPOT_VIEW: localTile * 2;
			default: localTile;
		}
	}

	static function drawCasters(g: kha.graphics4.Graphics, view: Int) {
		var o = view * VIEW_VEC4S * 4;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible || !mesh.visibleShadow) continue;
			if (!inView(mesh, o)) continue;
			// MeshObject.render() culls against the camera, skips objects hidden
			// from the camera and records the motion matrix for velocity; none of
			// that applies to a shadow view (objects hidden from the camera still
			// cast shadows in Eevee).
			var culling = mesh.frustumCulling;
			var cameraVisible = mesh.visibleMesh;
			mesh.frustumCulling = false;
			mesh.visibleMesh = true;
			#if arm_veloc savedPrevMatrix.setFrom(mesh.prevMatrix); #end
			mesh.render(g, CONTEXT, NO_BIND_PARAMS);
			#if arm_veloc mesh.prevMatrix.setFrom(savedPrevMatrix); #end
			mesh.frustumCulling = culling;
			mesh.visibleMesh = cameraVisible;
		}
	}

	/**
		Half the extent of the mesh's box along the unit direction (nx, ny, nz):
		tighter than the bounding sphere for long or flat objects, which would
		otherwise stretch the depth ranges (coarser cascades, wider blocker search).
	**/
	static function halfExtent(mesh: MeshObject, nx: Float, ny: Float, nz: Float): Float {
		var m = mesh.transform.world;
		var dim = mesh.transform.dim;
		return axisExtent(m._00, m._01, m._02, dim.x, nx, ny, nz)
			+ axisExtent(m._10, m._11, m._12, dim.y, nx, ny, nz)
			+ axisExtent(m._20, m._21, m._22, dim.z, nx, ny, nz);
	}

	/** Half of one box axis (direction a, size `size` in local units) projected on n. **/
	static inline function axisExtent(ax: Float, ay: Float, az: Float, size: Float, nx: Float, ny: Float, nz: Float): Float {
		var length = Math.sqrt(ax * ax + ay * ay + az * az);
		return length > 0 ? 0.5 * size * Math.abs(ax * nx + ay * ny + az * nz) / length : 0.0;
	}

	/** Sun soft shadow width relative to the physical penumbra for Eevee's step count. **/
	static function penumbraScale(steps: Int): Float {
		if (steps <= STEP_COUNTS[0]) return STEP_WIDTHS[0];
		for (i in 1...STEP_COUNTS.length) {
			if (steps <= STEP_COUNTS[i]) {
				var t = (steps - STEP_COUNTS[i - 1]) / (STEP_COUNTS[i] - STEP_COUNTS[i - 1]);
				return STEP_WIDTHS[i - 1] + (STEP_WIDTHS[i] - STEP_WIDTHS[i - 1]) * t;
			}
		}
		return STEP_WIDTHS[STEP_WIDTHS.length - 1];
	}

	/** Local light soft shadow width: measured 1.10 at 6 steps, 1.00 at 16 (held outside). **/
	static function penumbraScaleLocal(steps: Int): Float {
		var t = Math.min(Math.max((steps - 6) / 10.0, 0.0), 1.0);
		return 1.10 - 0.10 * t;
	}

	/** Bounding box of the mesh against the view's tile and depth range. **/
	static function inView(mesh: MeshObject, o: Int): Bool {
		var t = mesh.transform;
		var x = t.worldx(), y = t.worldy(), z = t.worldz();
		var v = views;
		if (v[o + 23] > 0.5) {
			// Perspective: in front of the face and within its range (sphere test)
			var fx = v[o + 12], fy = v[o + 13], fz = v[o + 14];
			var along = fx * x + fy * y + fz * z + v[o + 15];
			var r = halfExtent(mesh, fx, fy, fz) + t.radius * 0.5;
			return along + r > 0 && along - r < v[o + 21] + v[o + 22];
		}
		for (row in 0...2) {
			var i = o + row * 4;
			var scale = Math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]);
			var c = v[i] * x + v[i + 1] * y + v[i + 2] * z + v[i + 3];
			var r = halfExtent(mesh, v[i] / scale, v[i + 1] / scale, v[i + 2] / scale) * scale;
			if (c + r < 0 || c - r > 1) return false;
		}
		var i = o + 8;
		var scale = Math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]);
		var depth = v[i] * x + v[i + 1] * y + v[i + 2] * z + v[i + 3];
		return depth - halfExtent(mesh, v[i] / scale, v[i + 1] / scale, v[i + 2] / scale) * scale <= 1;
	}

	/** Perspective view from (px, py, pz) along (fx, fy, fz) with tan(half angle) `halfTan`. **/
	static function setPerspective(view: Int, px: Float, py: Float, pz: Float,
			fx: Float, fy: Float, fz: Float, halfTan: Float, far: Float) {
		// Up: world Z, or world Y when looking along Z
		var ux = 0.0, uy = 0.0, uz = 1.0;
		if (Math.abs(fz) > 0.99) { ux = 0.0; uy = 1.0; uz = 0.0; }
		var rx = fy * uz - fz * uy, ry = fz * ux - fx * uz, rz = fx * uy - fy * ux;
		var rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
		rx /= rl; ry /= rl; rz /= rl;
		ux = ry * fz - rz * fy; uy = rz * fx - rx * fz; uz = rx * fy - ry * fx;
		var k = 0.5 / halfTan;
		var range = far - LOCAL_NEAR;
		var o = view * VIEW_VEC4S * 4;
		var pf = fx * px + fy * py + fz * pz;
		// u = 0.5 + 0.5 (r.q) / (t f.q), v = 0.5 - 0.5 (u.q) / (t f.q), q = p - light
		var ax = 0.5 * fx + k * rx, ay = 0.5 * fy + k * ry, az = 0.5 * fz + k * rz;
		setRow(o, ax, ay, az, -(ax * px + ay * py + az * pz));
		var bx = 0.5 * fx - k * ux, by = 0.5 * fy - k * uy, bz = 0.5 * fz - k * uz;
		setRow(o + 4, bx, by, bz, -(bx * px + by * py + bz * pz));
		setRow(o + 8, fx / range, fy / range, fz / range, (-pf - LOCAL_NEAR) / range);
		setRow(o + 12, fx, fy, fz, -pf);
		setRow(o + 20, k, LOCAL_NEAR, range, 1.0);
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
			var x = t.worldx(), y = t.worldy(), z = t.worldz();
			var d = (x - cx) * look.x + (y - cy) * look.y + (z - cz) * look.z;
			var r = halfExtent(mesh, look.x, look.y, look.z);
			if (d - r < receiverNear) receiverNear = d - r;
			if (d + r > receiverFar) receiverFar = d + r;
			if (mesh.visibleShadow) {
				var along = x * dx + y * dy + z * dz - halfExtent(mesh, dx, dy, dz);
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
		for (c in 0...SUN_CASCADES) {
			var tile = Math.max(tiles[first + c][2], 1);
			var d0 = split(start, end, c / SUN_CASCADES, lambda);
			var d1 = split(start, end, (c + 1) / SUN_CASCADES, lambda);
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
			setRow(o + 12, 0, 0, 0, 1);
			setRow(o + 20, s, 0, zrange, 0);
		}
	}

	/**
		World -> clip for drawing into the tile: x = 2 u_num - w, y = w - 2 v_num,
		z: linear (orthographic) or the usual perspective depth over [near, far].
	**/
	static function setClipMatrix(view: Int) {
		var flip = kha.Image.renderTargetsInvertedY() ? -1.0 : 1.0;
		var v = views;
		var o = view * VIEW_VEC4S * 4;
		var zx, zy, zz, zw;
		if (v[o + 23] > 0.5) {
			var near = v[o + 21], far = v[o + 21] + v[o + 22];
			var a = (far + near) / (far - near), b = -2 * far * near / (far - near);
			zx = a * v[o + 12]; zy = a * v[o + 13]; zz = a * v[o + 14]; zw = a * v[o + 15] + b;
		}
		else {
			zx = 2 * v[o + 8]; zy = 2 * v[o + 9]; zz = 2 * v[o + 10]; zw = 2 * v[o + 11] - 1;
		}
		var m = clipMatrices[view];
		m._00 = 2 * v[o] - v[o + 12]; m._10 = 2 * v[o + 1] - v[o + 13]; m._20 = 2 * v[o + 2] - v[o + 14]; m._30 = 2 * v[o + 3] - v[o + 15];
		m._01 = flip * (v[o + 12] - 2 * v[o + 4]); m._11 = flip * (v[o + 13] - 2 * v[o + 5]);
		m._21 = flip * (v[o + 14] - 2 * v[o + 6]); m._31 = flip * (v[o + 15] - 2 * v[o + 7]);
		m._02 = zx; m._12 = zy; m._22 = zz; m._32 = zw;
		m._03 = v[o + 12]; m._13 = v[o + 13]; m._23 = v[o + 14]; m._33 = v[o + 15];
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
