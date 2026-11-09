package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import kha.arrays.Float32Array;
import iron.RenderPath;
import iron.Scene;
import iron.math.Mat4;
import iron.math.Vec4;
import iron.object.MeshObject;

/**
	Shadow maps for the Viewport renderer. All shadow views share one depth atlas,
	just big enough for this frame's views (Eevee's shadow_pool_size is its limit).
	Each frame the lights request views, then render() sizes the views, packs
	them into the atlas and draws the shadow casters into each view's tile.

	Sun lights get orthographic views over the camera's depth range: SUN_CASCADES
	growing slices with a perspective camera; with an orthographic camera as many
	equal slices as keep the views smallest (sunSlices()). Each view is fitted with
	a bounding sphere (its size does not change when the camera turns) and snapped
	to whole texels, so shadow edges stay still while the camera moves. Its texels
	are screen-pixel sized at the view's nearest point (TEXEL_PER_PIXEL), as
	measured on Eevee: a hard edge is ~1.4 px wide at any zoom and render size.
	Spot lights get one perspective view over their cone, point and area lights
	the six faces of a cube (slightly widened so filtering never runs off a face),
	at fixed fractions of the pool's atlas. When the views do not fit the pool's
	atlas, all of them shrink by the same factor (packTiles()).

	The shader side is Shaders/vpraster/vpraster_lights.glsl. Per view, VIEW_VEC4S vec4:
	  0, 1: u and v numerators (tile 0..1, v down), 2: linear depth (0..1),
	  3: the divisor w (sun: 1), 4: the tile in the atlas (x, y, width, height; mirrored
	  where render targets are upside down, see render()),
	  5: tile uv per metre at w = 1, near distance (m), depth range (m), perspective
**/
class RasterShadows {

	// Read by the build (blender/arm/viewport/engine.py) for the shaders and shader data
	public static inline var MAX_VIEWS = 32;
	static inline var VIEW_VEC4S = 6;
	static inline var SUN_CASCADES = 4; // with a perspective camera
	static inline var CONTEXT = "vpraster_shadow";
	/** Perspective views: the casters write the linear depth themselves (vpraster_shadow_perspective.frag.glsl). **/
	static inline var PERSPECTIVE_CONTEXT = "vpraster_shadow_perspective";
	static inline var TARGET = "vpraster_shadow_atlas";
	static inline var MIN_ATLAS = 256;
	static inline var MAX_ATLAS = 4096;
	static inline var MIN_TILE = 128;
	static inline var TILE_STEP = 64; // tile sizes (texels): fewer size changes while zooming
	/** Sun texel size over the screen pixel's at the view's nearest point (calibrated on the hard edge width). **/
	static inline var TEXEL_PER_PIXEL = 1.0;
	/** Frames a smaller atlas must be enough for before the atlas shrinks (zooming back and forth). **/
	static inline var SHRINK_FRAMES = 120;
	static inline var CUBE_WIDEN = 1.1; // tan of a cube face's half angle (45 degrees + margin)
	static inline var LOCAL_NEAR = 0.05;
	static inline var LOCAL_FAR = 100.0; // without an influence radius

	public static var views = new Float32Array(MAX_VIEWS * VIEW_VEC4S * 4);
	public static var info = new Vec4();
	/** Clip matrix and linear depth row of the tile being drawn (links _vprasterShadowVP, _vprasterShadowDepth). **/
	public static var viewProjection = Mat4.identity();
	public static var depthRow = new Vec4();
	public static var atlas(get, never): kha.Image;

	// Measured on Eevee (phase 3.0): soft shadow width relative to the physical
	// penumbra for shadow_step_count 1, 2, 3, 4, 6, 8, 12, 16 (constant above 16).
	// Sun lights; local lights measured 1.10 at 6 steps and 1.00 at 16.
	static var STEP_COUNTS = [1, 2, 3, 4, 6, 8, 12, 16];
	static var STEP_WIDTHS = [0.19, 0.33, 0.47, 0.57, 0.70, 0.77, 0.85, 0.88];

	static var viewCount = 0;
	static var suns: Array<Vec4> = []; // light direction (xyz), first view (w)
	static var sunCount = 0;
	static var clipMatrices = [for (_ in 0...MAX_VIEWS) Mat4.identity()];
	static var tiles = [for (_ in 0...MAX_VIEWS) [0, 0, 0]]; // x, y, size in texels
	static inline var SUN_VIEW = 0;
	static inline var SPOT_VIEW = 1;
	static inline var CUBE_VIEW = 2;
	static var viewKinds = [for (_ in 0...MAX_VIEWS) SUN_VIEW];
	static var needs = [for (_ in 0...MAX_VIEWS) 0.0]; // texels each view asks for this frame
	static var order = [for (_ in 0...MAX_VIEWS) 0]; // views by size, largest first (packTiles)
	static var groups = [for (_ in 0...MAX_VIEWS) 0]; // views of the light whose first view this is
	// Per sun, from addSun() to placeSun(): the light's basis, the nearest caster along
	// the light (w of `right`), the depth range to cover (start, end) and the
	// views' bounding spheres (centre, radius; per view)
	static var sunRight = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var sunUp = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var sunRange = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var spheres = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var shrinkFrames = 0;
	static var screenHeight = 1; // pixels of the lit image, for the sun views' texel size
	// Cube face directions (x, y, z per face)
	static var CUBE_FACES = [1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0];
	static var NO_BIND_PARAMS: Array<String> = [];
	static var atlasSize = 0;
	static var target: iron.RenderPath.RenderTarget = null;

	static var corners = [for (_ in 0...8) new Vec4()];
	static var invVP = Mat4.identity();

	/** Starts a frame: drops the previous frame's views. **/
	public static function begin() {
		viewCount = 0;
		sunCount = 0;
	}

	/** The number of views of the light whose first view is `first` (the shader's loop). **/
	public static inline function viewsAt(first: Int): Int {
		return groups[first];
	}

	/**
		Adds the views of a sun travelling along (dx, dy, dz), normalised. Returns
		the first view index, or -1 when shadows are off or the atlas is full.
	**/
	public static function addSun(dx: Float, dy: Float, dz: Float): Int {
		var camera = Scene.active.camera;
		if (!RasterSettings.useShadows || camera == null) return -1;
		var near = camera.data.raw.near_plane;
		var far = camera.data.raw.far_plane;

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

		var count = sunSlices(camera, end - start);
		if (viewCount + count > MAX_VIEWS) return -1;
		var first = viewCount;
		viewCount += count;
		for (i in 0...count) viewKinds[first + i] = SUN_VIEW;
		groups[first] = count;
		if (sunCount == suns.length) suns.push(new Vec4());
		var index = sunCount++;
		suns[index].set(dx, dy, dz, first);

		// Light basis: d travels with the light, right/up span the tiles
		var ux = 0.0, uy = 0.0, uz = 1.0;
		if (Math.abs(dz) > 0.99) { ux = 0.0; uy = 1.0; uz = 0.0; }
		var rx = uy * dz - uz * dy, ry = uz * dx - ux * dz, rz = ux * dy - uy * dx;
		var rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
		rx /= rl; ry /= rl; rz /= rl;
		sunRight[index].set(rx, ry, rz, casterMin);
		sunUp[index].set(ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx);
		sunRange[index].set(start, end, 0);
		return first;
	}

	/**
		Views of a sun over `depth` metres of the camera's view. Perspective:
		SUN_CASCADES, each at the texel size its nearest point needs. Orthographic
		(pixels the same size at every depth): n equal slices of a W x H x depth box
		have bounding spheres of n (W^2 + H^2) / 4 + depth^2 / (4 n) square metres in
		all, the least at n = depth / sqrt(W^2 + H^2) - one view for a shallow box,
		more as the box gets deep.
	**/
	static function sunSlices(camera: iron.object.CameraObject, depth: Float): Int {
		if (camera.P._23 != 0) return SUN_CASCADES;
		var w = 2 / camera.P._00, h = 2 / camera.P._11;
		var n = Math.round(depth / Math.sqrt(w * w + h * h));
		return Std.int(Math.max(1, Math.min(n, SUN_CASCADES)));
	}

	/**
		Adds the views of a spot (one view over its cone, `spotSize` full angle) or a
		point/area light (six cube faces) at (px, py, pz), shining along (dx, dy, dz).
		`range` is the light's influence radius (0 = none). Returns the first view.
	**/
	public static function addLocal(spot: Bool, px: Float, py: Float, pz: Float,
			dx: Float, dy: Float, dz: Float, spotSize: Float, range: Float): Int {
		var count = spot ? 1 : 6;
		if (!RasterSettings.useShadows || viewCount + count > MAX_VIEWS) return -1;
		var first = viewCount;
		viewCount += count;
		for (i in 0...count) viewKinds[first + i] = spot ? SPOT_VIEW : CUBE_VIEW;
		groups[first] = count;
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
		var hdr = path.renderTargets.get(RenderPathViewportRaster.HDR);
		screenHeight = hdr != null && hdr.image != null ? hdr.image.height : iron.App.h();
		// Sizes: suns from the screen (their bounding spheres first), local lights fixed
		var pool = poolAtlas();
		for (i in 0...sunCount) fitSun(i, pool);
		for (view in 0...viewCount) {
			switch (viewKinds[view]) {
				case SPOT_VIEW: needs[view] = pool / 4;
				case CUBE_VIEW: needs[view] = pool / 8;
				default:
			}
		}
		// The smallest atlas holding every view as asked, else the pool's with the
		// views shrunk alike
		var side = MIN_ATLAS;
		while (side < pool && !packTiles(side, 1.0)) side *= 2;
		ensureAtlas(path, side, pool);
		info.set(1.0 / atlasSize, penumbraScale(RasterSettings.shadowStepCount), RasterTaa.frame % 64,
			penumbraScaleLocal(RasterSettings.shadowStepCount));
		if (viewCount == 0) return;
		if (!packTiles(atlasSize, 1.0)) {
			var fits = 0.0, fails = 1.0;
			for (_ in 0...10) {
				var scale = (fits + fails) / 2;
				if (packTiles(atlasSize, scale)) { fits = scale; } else { fails = scale; }
			}
			packTiles(atlasSize, fits); // views that still find no room get an empty tile
		}
		// Placed once the tiles are known: their texel snapping needs the tile size
		for (i in 0...sunCount) placeSun(i);
		// Tiles are drawn the same way on every backend (setClipMatrix). Where render
		// targets are upside down (OpenGL, WebGL) a tile's rows are too: its rectangle
		// starts at its other edge with a negative height, so the shaders' lookups
		// (rect.xy + uv * rect.zw) mirror within the tile. Flipping the projection
		// instead would also reverse the triangles' winding, and with it which faces
		// the shadow pass culls.
		var mirrored = kha.Image.renderTargetsInvertedY();
		for (view in 0...viewCount) {
			var o = view * VIEW_VEC4S * 4 + 16;
			var t = tiles[view];
			var size = t[2] / atlasSize;
			if (mirrored) setRow(o, t[0] / atlasSize, t[1] / atlasSize + size, size, -size);
			else setRow(o, t[0] / atlasSize, t[1] / atlasSize, size, size);
			setClipMatrix(view);
		}

		ViewportTargets.setAlone(path, TARGET);
		var g = path.currentG;
		// Depth only (the lighting pass reads the depth buffer; the colour image is never
		// written): 1 = nothing in the way
		g.clear(null, 1.0);
		for (view in 0...viewCount) {
			var t = tiles[view];
			g.viewport(t[0], t[1], t[2], t[2]);
			viewProjection.setFrom(clipMatrices[view]);
			var o = view * VIEW_VEC4S * 4 + 8;
			depthRow.set(views[o], views[o + 1], views[o + 2], views[o + 3]);
			drawCasters(g, view);
		}
	}

	/**
		Shelf packing of the views' square tiles into a `side` x `side` atlas, largest
		first: each view's size is its need times `scale`, in steps of TILE_STEP texels.
		Returns whether all fit; the ones that do not get an empty tile.
	**/
	static function packTiles(side: Int, scale: Float): Bool {
		for (view in 0...viewCount) {
			// Not clipped to `side`: a tile larger than the atlas does not fit it
			var size = Math.ceil(needs[view] * scale / TILE_STEP) * TILE_STEP;
			tiles[view][2] = Std.int(Math.max(size, MIN_TILE));
			// Insertion into `order`, largest first (no allocation: this runs every frame)
			var i = view;
			while (i > 0 && tiles[order[i - 1]][2] < tiles[view][2]) {
				order[i] = order[i - 1];
				i--;
			}
			order[i] = view;
		}
		var x = 0, y = 0, shelf = 0, all = true;
		for (i in 0...viewCount) {
			var view = order[i];
			var size = tiles[view][2];
			if (x + size > side) { // next shelf, as tall as its first (largest) tile
				x = 0;
				y += shelf;
				shelf = 0;
			}
			if (y + size > side) {
				tiles[view][2] = 0;
				all = false;
				continue;
			}
			tiles[view][0] = x;
			tiles[view][1] = y;
			x += size;
			if (shelf == 0) shelf = size;
		}
		return all;
	}

	static function drawCasters(g: kha.graphics4.Graphics, view: Int) {
		var o = view * VIEW_VEC4S * 4;
		// The lighting pass reads the atlas's depth as the view's linear depth: the
		// orthographic clip matrix gives it as is, perspective views write it per pixel
		var context = views[o + 23] > 0.5 ? PERSPECTIVE_CONTEXT : CONTEXT;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible || !mesh.visibleShadow) continue;
			if (!inView(mesh, o)) continue;
			// MeshObject.render() culls against the camera and skips objects hidden
			// from the camera; neither applies to a shadow view (objects hidden from
			// the camera still cast shadows in Eevee).
			var culling = mesh.frustumCulling;
			var cameraVisible = mesh.visibleMesh;
			mesh.frustumCulling = false;
			mesh.visibleMesh = true;
			mesh.render(g, context, NO_BIND_PARAMS);
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

	/**
		Sizes the views of sun `index` (addSun()): splits the camera's depth range,
		fits each slice's bounding sphere, and asks for a tile whose texels are
		TEXEL_PER_PIXEL screen pixels at the slice's nearest point (at most `pool`).
	**/
	static function fitSun(index: Int, pool: Int) {
		var first = Std.int(suns[index].w);
		var camera = Scene.active.camera;
		var near = camera.data.raw.near_plane;
		var far = camera.data.raw.far_plane;
		var start = sunRange[index].x, end = sunRange[index].y;

		// Rays through the screen corners: points at view distance `near` and `far`
		invVP.getInverse(camera.VP);
		for (i in 0...4) {
			var sx = (i & 1) == 0 ? -1.0 : 1.0;
			var sy = (i & 2) == 0 ? -1.0 : 1.0;
			corners[i].set(sx, sy, -1, 1).applyproj(invVP);
			corners[i + 4].set(sx, sy, 1, 1).applyproj(invVP);
		}

		// A screen pixel's size in metres: at distance 1 (perspective) or anywhere (orthographic)
		var perspective = camera.P._23 != 0;
		var pixel = 2.0 / (camera.P._11 * screenHeight);
		var count = groups[first];
		var lambda = perspective ? 0.75 : 0.0; // logarithmic share of the split scheme
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
			radius = Math.pow(2, Math.ceil(Math.log(radius) / Math.log(2) * 8) / 8); // fewer size changes
			spheres[first + c].set(mx, my, mz, radius);

			var texel = TEXEL_PER_PIXEL * pixel * (perspective ? Math.max(d0, near) : 1.0);
			needs[first + c] = Math.min(2 * radius / texel, pool);
		}
	}

	/** Writes the views of sun `index` for their tiles (fitSun() first): snapped to whole texels. **/
	static function placeSun(index: Int) {
		var sun = suns[index];
		var dx = sun.x, dy = sun.y, dz = sun.z;
		var first = Std.int(sun.w);
		var r = sunRight[index], u = sunUp[index];
		var casterMin = r.w;
		for (c in 0...groups[first]) {
			var view = first + c;
			var tile = Math.max(tiles[view][2], 1);
			var sphere = spheres[view];
			var radius = sphere.w;
			var texel = 2 * radius / tile;
			var centerRight = Math.floor((sphere.x * r.x + sphere.y * r.y + sphere.z * r.z) / texel) * texel;
			var centerUp = Math.floor((sphere.x * u.x + sphere.y * u.y + sphere.z * u.z) / texel) * texel;
			var centerDepth = sphere.x * dx + sphere.y * dy + sphere.z * dz;
			var zmin = Math.min(casterMin, centerDepth - radius);
			var zmax = centerDepth + radius;
			var zrange = Math.max(zmax - zmin, 1e-4);

			var o = view * VIEW_VEC4S * 4;
			var s = 1.0 / (2 * radius);
			setRow(o, r.x * s, r.y * s, r.z * s, 0.5 - centerRight * s);
			setRow(o + 4, -u.x * s, -u.y * s, -u.z * s, 0.5 + centerUp * s);
			setRow(o + 8, dx / zrange, dy / zrange, dz / zrange, -zmin / zrange);
			setRow(o + 12, 0, 0, 0, 1);
			setRow(o + 20, s, 0, zrange, 0);
		}
	}

	/**
		World -> clip for drawing into the tile: x = 2 u_num - w, y = w - 2 v_num,
		z: linear (orthographic) or the usual perspective depth over [near, far]
		(perspective casters then write the linear depth themselves, drawCasters()).
	**/
	static function setClipMatrix(view: Int) {
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
		m._01 = v[o + 12] - 2 * v[o + 4]; m._11 = v[o + 13] - 2 * v[o + 5];
		m._21 = v[o + 14] - 2 * v[o + 6]; m._31 = v[o + 15] - 2 * v[o + 7];
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

	/** The atlas limit: the largest power of two whose depth + R32 texels fit Eevee's pool size. **/
	static function poolAtlas(): Int {
		var bytes = RasterSettings.shadowPoolSize * 1024.0 * 1024.0;
		var size = MIN_ATLAS;
		while (size * 2 <= MAX_ATLAS && (size * 2.0) * (size * 2.0) * 8 <= bytes) size *= 2;
		return size;
	}

	/**
		An atlas of side `size`: made again at once when it must grow (or the pool
		shrank below it), after SHRINK_FRAMES frames of needing less when it may shrink.
	**/
	static function ensureAtlas(path: RenderPath, size: Int, pool: Int) {
		if (target != null) {
			if (size == atlasSize || (size < atlasSize && atlasSize <= pool && ++shrinkFrames < SHRINK_FRAMES)) {
				if (size == atlasSize) shrinkFrames = 0;
				return;
			}
			target.image.unload();
		}
		shrinkFrames = 0;
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
