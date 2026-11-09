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
	just big enough for this frame's views. Eevee's shadow_pool_size sets its
	largest size. Each frame, the lights ask for views while RasterLights packs
	them. Then render() sizes the views, packs them into the atlas and draws the
	shadow casters into each view's tile.

	Sun lights get orthographic views over the camera's depth range. With a
	perspective camera, these are SUN_CASCADES slices that grow with distance.
	With an orthographic camera, they are as many equal slices as keep the views
	smallest (sunSlices()). Each view is fitted around a bounding sphere, so its
	size does not change when the camera turns. It is snapped to whole texels, so
	shadow edges stay still while the camera moves. Its texels are about one screen
	pixel at the view's nearest point (TEXEL_PER_PIXEL). As in Eevee, a hard
	shadow edge then has the same width in pixels at any zoom and render size.

	Spot lights get one perspective view over their cone. Point and area lights
	get the six faces of a cube, slightly widened so filtering never runs off a
	face. These views take fixed fractions of the largest atlas. When the views do
	not fit the largest atlas, all of them shrink by the same factor (packTiles()).

	The shaders read the views from `views` (`arm_shadow_view()` in
	Shaders/vpraster/vpraster_lights.glsl). Each view takes VIEW_VEC4S (6) vec4,
	the rows named below:
	  ROW_U, ROW_V: dot one with a world position (1 in w) and divide by ROW_W's to get
	                the tile coordinates u and v (0..1, v down)
	  ROW_DEPTH:    the same for the linear depth (0..1 over the view's depth range)
	  ROW_W:        the divisor w (orthographic views: 0, 0, 0, 1)
	  ROW_TILE:     the tile in the atlas: x, y, width, height (upside down where render
	                targets are; see render())
	  ROW_EXTRA:    tile uv per metre at w = 1, near distance, depth range (metres),
	                1 for a perspective view
**/
class RasterShadows {

	// The build reads these for the shaders and shader data (blender/arm/viewport/raster/engine.py)
	public static inline var MAX_VIEWS = 32;
	static inline var VIEW_VEC4S = 6;
	static inline var SUN_CASCADES = 4; // sun views with a perspective camera
	static inline var CONTEXT = "vpraster_shadow";
	/**
		The casters' pass for perspective views. It writes the linear depth itself
		(vpraster_shadow_perspective.frag.glsl). Iron finds a material's pass by name
		prefix, so neither pass name may start with the other.
	**/
	static inline var PERSPECTIVE_CONTEXT = "vpraster_perspective_shadow";
	static inline var TARGET = "vpraster_shadow_atlas";
	static inline var MIN_ATLAS = 256;
	static inline var MAX_ATLAS = 4096;
	static inline var MIN_TILE = 128;
	static inline var TILE_STEP = 64; // tile sizes are multiples of this (texels), so they change less often while zooming
	/** A sun texel's size relative to a screen pixel at the view's nearest point. Fitted to match Eevee's hard shadow edges. **/
	static inline var TEXEL_PER_PIXEL = 1.0;
	/** Frames a smaller atlas must be enough for before the atlas shrinks, so zooming back and forth does not remake it. **/
	static inline var SHRINK_FRAMES = 120;
	static inline var CUBE_WIDEN = 1.1; // tan of a cube face's half angle: 45 degrees plus a margin
	static inline var LOCAL_NEAR = 0.05;
	static inline var LOCAL_FAR = 100.0; // for lights without an influence radius

	// Offsets of each row in a view's floats (see the layout above)
	static inline var ROW_U = 0;
	static inline var ROW_V = 4;
	static inline var ROW_DEPTH = 8;
	static inline var ROW_W = 12;
	static inline var ROW_TILE = 16;
	static inline var ROW_EXTRA = 20;
	// The values of ROW_EXTRA
	static inline var UV_PER_METRE = ROW_EXTRA;
	static inline var NEAR = ROW_EXTRA + 1;
	static inline var DEPTH_RANGE = ROW_EXTRA + 2;
	static inline var PERSPECTIVE = ROW_EXTRA + 3;

	public static var views = new Float32Array(MAX_VIEWS * VIEW_VEC4S * 4);
	/**
		Shadow settings for the shaders (u_armShadowInfo):
		x = 1 / atlas size in texels, y = width of sun penumbras (see penumbraScale()),
		z = frame number for the noise, w = width of point, spot and area light
		penumbras (see penumbraScaleLocal()).
	**/
	public static var info = new Vec4();
	/** The clip matrix and linear depth row of the tile being drawn (links _vprasterShadowVP, _vprasterShadowDepth). **/
	public static var viewProjection = Mat4.identity();
	public static var depthRow = new Vec4();
	public static var atlas(get, never): kha.Image;

	// Sun soft shadow width relative to the physical penumbra, for each
	// shadow_step_count below (constant above 16). Fitted to match Eevee.
	static var STEP_COUNTS = [1, 2, 3, 4, 6, 8, 12, 16];
	static var STEP_WIDTHS = [0.19, 0.33, 0.47, 0.57, 0.70, 0.77, 0.85, 0.88];

	static var viewCount = 0;
	static var suns: Array<Vec4> = []; // per sun: light direction (xyz), first view (w)
	static var sunCount = 0;
	static var clipMatrices = [for (_ in 0...MAX_VIEWS) Mat4.identity()];
	static var tiles = [for (_ in 0...MAX_VIEWS) [0, 0, 0]]; // per view: x, y, size in texels
	static inline var SUN_VIEW = 0;
	static inline var SPOT_VIEW = 1;
	static inline var CUBE_VIEW = 2;
	static var viewKinds = [for (_ in 0...MAX_VIEWS) SUN_VIEW];
	static var needs = [for (_ in 0...MAX_VIEWS) 0.0]; // texels each view asks for this frame
	static var order = [for (_ in 0...MAX_VIEWS) 0]; // views by size, largest first (packTiles())
	static var groups = [for (_ in 0...MAX_VIEWS) 0]; // at a light's first view: how many views it has
	// Per sun, kept from addSun() to placeSun(): the light's basis (right, up), the
	// nearest caster along the light (w of `right`), the depth range to cover
	// (start, end), and each view's bounding sphere (centre, radius)
	static var sunRight = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var sunUp = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var sunRange = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var spheres = [for (_ in 0...MAX_VIEWS) new Vec4()];
	static var shrinkFrames = 0;
	static var screenHeight = 1; // height of the lit image in pixels, for the sun views' texel size
	// Cube face directions (x, y, z per face)
	static var CUBE_FACES = [1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0];
	static var NO_BIND_PARAMS: Array<String> = [];
	static var atlasSize = 0;
	static var target: iron.RenderPath.RenderTarget = null;

	static var corners = [for (_ in 0...8) new Vec4()];
	static var invVP = Mat4.identity();

	/** Starts a frame. Drops the previous frame's views. **/
	public static function begin() {
		viewCount = 0;
		sunCount = 0;
	}

	/** The number of views of the light whose first view is `first`. The shaders loop over them. **/
	public static inline function viewsAt(first: Int): Int {
		return groups[first];
	}

	/**
		Adds the views of a sun whose light travels along the unit vector (dx, dy, dz).
		Returns the first view's index, or -1 when shadows are off or MAX_VIEWS is reached.
		The views are sized in render() and placed once the tiles are known.
	**/
	public static function addSun(dx: Float, dy: Float, dz: Float): Int {
		var camera = Scene.active.camera;
		if (!RasterSettings.useShadows || camera == null) return -1;
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

		// The light's basis: d travels with the light, and right and up span the tiles
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
		The number of views of a sun over `depth` metres of the camera's view.

		A perspective camera gets SUN_CASCADES views, each at the texel size its
		nearest point needs.

		An orthographic camera's pixels are the same size at every depth. Its view
		is a W x H x depth box. Cut into n equal slices, the slices' bounding spheres
		have n (W^2 + H^2) / 4 + depth^2 / (4 n) square metres in all. That is least
		at n = depth / sqrt(W^2 + H^2): one view for a shallow box, more as it gets deeper.
	**/
	static function sunSlices(camera: iron.object.CameraObject, depth: Float): Int {
		if (camera.P._23 != 0) return SUN_CASCADES;
		var w = 2 / camera.P._00, h = 2 / camera.P._11;
		var n = Math.round(depth / Math.sqrt(w * w + h * h));
		return Std.int(Math.max(1, Math.min(n, SUN_CASCADES)));
	}

	/**
		Adds the views of a light at (px, py, pz) shining along (dx, dy, dz). A spot
		gets one view over its cone (`spotSize` is the full angle). A point or area
		light gets six cube faces. `range` is the light's influence radius (0 = none).
		Returns the first view's index, or -1 when shadows are off or MAX_VIEWS is reached.
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

	/**
		Sizes this frame's views, packs them into the atlas and draws every view's
		shadow casters into its tile. The renderer calls it after RasterLights.update(),
		before the material pass.
	**/
	public static function render(path: RenderPath) {
		var hdr = path.renderTargets.get(RenderPathViewportRaster.HDR);
		screenHeight = hdr != null && hdr.image != null ? hdr.image.height : iron.App.h();
		// View sizes: suns from the screen (bounding spheres first), local lights fixed
		var pool = poolAtlas();
		for (i in 0...sunCount) fitSun(i, pool);
		for (view in 0...viewCount) {
			switch (viewKinds[view]) {
				case SPOT_VIEW: needs[view] = pool / 4;
				case CUBE_VIEW: needs[view] = pool / 8;
				default:
			}
		}
		// The smallest atlas that holds every view at the size it asks for. If none
		// does, the largest atlas, with all views shrunk by the same factor.
		var side = MIN_ATLAS;
		while (side < pool && !packTiles(side, 1.0)) side *= 2;
		ensureAtlas(path, side, pool);
		info.set(1.0 / atlasSize, penumbraScale(RasterSettings.shadowStepCount), RasterTaa.noiseFrame(),
			penumbraScaleLocal(RasterSettings.shadowStepCount));
		if (viewCount == 0) return;
		if (!packTiles(atlasSize, 1.0)) {
			// Bisection for the largest shrink factor that fits
			var fits = 0.0, fails = 1.0;
			for (_ in 0...10) {
				var scale = (fits + fails) / 2;
				if (packTiles(atlasSize, scale)) { fits = scale; } else { fails = scale; }
			}
			packTiles(atlasSize, fits); // views that still find no room get an empty tile
		}
		// Suns are placed once the tiles are known: their texel snapping needs the tile size
		for (i in 0...sunCount) placeSun(i);
		// Tiles are drawn the same way on every backend (setClipMatrix()). Where render
		// targets are upside down (OpenGL, WebGL), so are a tile's rows. So its
		// rectangle starts at its other edge with a negative height, and the shaders'
		// lookups (rect.xy + uv * rect.zw) mirror within the tile. Flipping the
		// projection instead would also reverse the triangles' winding, and with it
		// which faces the shadow pass culls.
		var mirrored = kha.Image.renderTargetsInvertedY();
		for (view in 0...viewCount) {
			var o = viewOffset(view) + ROW_TILE;
			var t = tiles[view];
			var size = t[2] / atlasSize;
			if (mirrored) setRow(o, t[0] / atlasSize, t[1] / atlasSize + size, size, -size);
			else setRow(o, t[0] / atlasSize, t[1] / atlasSize, size, size);
			setClipMatrix(view);
		}

		ViewportTargets.setAlone(path, TARGET);
		var g = path.currentG;
		// Depth only: the lighting pass reads the depth buffer, and the colour image is
		// never written. 1 means nothing is in the way.
		g.clear(null, 1.0);
		for (view in 0...viewCount) {
			var t = tiles[view];
			g.viewport(t[0], t[1], t[2], t[2]);
			viewProjection.setFrom(clipMatrices[view]);
			var o = viewOffset(view) + ROW_DEPTH;
			depthRow.set(views[o], views[o + 1], views[o + 2], views[o + 3]);
			drawCasters(g, view);
		}
	}

	/**
		Packs the views' square tiles into a `side` x `side` atlas, in shelves, largest
		first. Each tile's size is its view's need times `scale`, rounded up to
		TILE_STEP texels. Returns whether all fit. The ones that do not fit get an
		empty tile.
	**/
	static function packTiles(side: Int, scale: Float): Bool {
		for (view in 0...viewCount) {
			// Not clamped to `side`: a tile larger than the atlas must fail to fit
			var size = Math.ceil(needs[view] * scale / TILE_STEP) * TILE_STEP;
			tiles[view][2] = Std.int(Math.max(size, MIN_TILE));
			// Insertion sort into `order`, largest first. It allocates nothing, as this runs every frame.
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
			if (x + size > side) { // start the next shelf. Each shelf is as tall as its first (largest) tile.
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

	/** Draws the shadow casters seen by `view` into its tile. **/
	static function drawCasters(g: kha.graphics4.Graphics, view: Int) {
		var o = viewOffset(view);
		// The lighting pass reads the atlas's depth as the view's linear depth. An
		// orthographic clip matrix gives that directly. Perspective views write it per pixel.
		var context = isPerspective(o) ? PERSPECTIVE_CONTEXT : CONTEXT;
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible || !mesh.visibleShadow) continue;
			if (!inView(mesh, o)) continue;
			// MeshObject.render() culls against the camera and skips objects hidden from
			// the camera. Neither applies to a shadow view: in Eevee, objects hidden from
			// the camera still cast shadows. So both are turned off for this draw.
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
		Half the extent of the mesh's box along the unit direction (nx, ny, nz).
		This is tighter than the bounding sphere for long or flat objects. The sphere
		would stretch the depth ranges, giving coarser cascades and a wider blocker search.
	**/
	static function halfExtent(mesh: MeshObject, nx: Float, ny: Float, nz: Float): Float {
		var m = mesh.transform.world;
		var dim = mesh.transform.dim;
		return axisExtent(m._00, m._01, m._02, dim.x, nx, ny, nz)
			+ axisExtent(m._10, m._11, m._12, dim.y, nx, ny, nz)
			+ axisExtent(m._20, m._21, m._22, dim.z, nx, ny, nz);
	}

	/** Half of one box axis (direction a, `size` in local units) projected on n. **/
	static inline function axisExtent(ax: Float, ay: Float, az: Float, size: Float, nx: Float, ny: Float, nz: Float): Float {
		var length = Math.sqrt(ax * ax + ay * ay + az * az);
		return length > 0 ? 0.5 * size * Math.abs(ax * nx + ay * ny + az * nz) / length : 0.0;
	}

	/** Sun soft shadow width relative to the physical penumbra, for Eevee's step count (interpolates STEP_WIDTHS). **/
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

	/**
		Soft shadow width of point, spot and area lights relative to the physical
		penumbra, for Eevee's step count. Fitted to match Eevee: it falls linearly
		from 6 to 16 steps and holds outside that range.
	**/
	static function penumbraScaleLocal(steps: Int): Float {
		var t = Math.min(Math.max((steps - 6) / 10.0, 0.0), 1.0);
		return 1.10 - 0.10 * t;
	}

	/** Whether the mesh's bounding box may reach into the view's tile and depth range. **/
	static function inView(mesh: MeshObject, o: Int): Bool {
		var t = mesh.transform;
		var x = t.worldx(), y = t.worldy(), z = t.worldz();
		var v = views;
		if (isPerspective(o)) {
			// Perspective: in front of the view's plane through the light, and within its range
			var fx = v[o + ROW_W], fy = v[o + ROW_W + 1], fz = v[o + ROW_W + 2];
			var along = fx * x + fy * y + fz * z + v[o + ROW_W + 3];
			var r = halfExtent(mesh, fx, fy, fz) + t.radius * 0.5;
			return along + r > 0 && along - r < v[o + NEAR] + v[o + DEPTH_RANGE];
		}
		for (k in 0...2) {
			var i = o + (k == 0 ? ROW_U : ROW_V);
			var scale = Math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]);
			var c = v[i] * x + v[i + 1] * y + v[i + 2] * z + v[i + 3];
			var r = halfExtent(mesh, v[i] / scale, v[i + 1] / scale, v[i + 2] / scale) * scale;
			if (c + r < 0 || c - r > 1) return false;
		}
		var i = o + ROW_DEPTH;
		var scale = Math.sqrt(v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2]);
		var depth = v[i] * x + v[i + 1] * y + v[i + 2] * z + v[i + 3];
		return depth - halfExtent(mesh, v[i] / scale, v[i + 1] / scale, v[i + 2] / scale) * scale <= 1;
	}

	/** Writes a perspective view from (px, py, pz) along (fx, fy, fz), with `halfTan` = tan(half angle). **/
	static function setPerspective(view: Int, px: Float, py: Float, pz: Float,
			fx: Float, fy: Float, fz: Float, halfTan: Float, far: Float) {
		// Up is world Z, or world Y when looking along Z
		var ux = 0.0, uy = 0.0, uz = 1.0;
		if (Math.abs(fz) > 0.99) { ux = 0.0; uy = 1.0; uz = 0.0; }
		var rx = fy * uz - fz * uy, ry = fz * ux - fx * uz, rz = fx * uy - fy * ux;
		var rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
		rx /= rl; ry /= rl; rz /= rl;
		ux = ry * fz - rz * fy; uy = rz * fx - rx * fz; uz = rx * fy - ry * fx;
		var k = 0.5 / halfTan;
		var range = far - LOCAL_NEAR;
		var o = viewOffset(view);
		var pf = fx * px + fy * py + fz * pz;
		// u = 0.5 + 0.5 (r.q) / (t f.q) and v = 0.5 - 0.5 (u.q) / (t f.q), where q = p - light and t = halfTan
		var ax = 0.5 * fx + k * rx, ay = 0.5 * fy + k * ry, az = 0.5 * fz + k * rz;
		setRow(o + ROW_U, ax, ay, az, -(ax * px + ay * py + az * pz));
		var bx = 0.5 * fx - k * ux, by = 0.5 * fy - k * uy, bz = 0.5 * fz - k * uz;
		setRow(o + ROW_V, bx, by, bz, -(bx * px + by * py + bz * pz));
		setRow(o + ROW_DEPTH, fx / range, fy / range, fz / range, (-pf - LOCAL_NEAR) / range);
		setRow(o + ROW_W, fx, fy, fz, -pf);
		setRow(o + ROW_EXTRA, k, LOCAL_NEAR, range, 1.0);
	}

	/**
		Sizes the views of sun `index` (see addSun()). Splits the camera's depth range,
		fits a bounding sphere around each slice, and asks for a tile whose texels are
		TEXEL_PER_PIXEL screen pixels at the slice's nearest point (at most `pool` texels).
	**/
	static function fitSun(index: Int, pool: Int) {
		var first = Std.int(suns[index].w);
		var camera = Scene.active.camera;
		var near = camera.data.raw.near_plane;
		var far = camera.data.raw.far_plane;
		var start = sunRange[index].x, end = sunRange[index].y;

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
		var count = groups[first];
		var lambda = perspective ? 0.75 : 0.0; // share of logarithmic splits (see split())
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
			radius = Math.pow(2, Math.ceil(Math.log(radius) / Math.log(2) * 8) / 8); // rounded up to steps of 2^(1/8), so the size changes less often
			spheres[first + c].set(mx, my, mz, radius);

			var texel = TEXEL_PER_PIXEL * pixel * (perspective ? Math.max(d0, near) : 1.0);
			needs[first + c] = Math.min(2 * radius / texel, pool);
		}
	}

	/** Writes the views of sun `index` for their tiles, snapped to whole texels. Runs after fitSun() and packTiles(). **/
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

			var o = viewOffset(view);
			var s = 1.0 / (2 * radius);
			setRow(o + ROW_U, r.x * s, r.y * s, r.z * s, 0.5 - centerRight * s);
			setRow(o + ROW_V, -u.x * s, -u.y * s, -u.z * s, 0.5 + centerUp * s);
			setRow(o + ROW_DEPTH, dx / zrange, dy / zrange, dz / zrange, -zmin / zrange);
			setRow(o + ROW_W, 0, 0, 0, 1);
			setRow(o + ROW_EXTRA, s, 0, zrange, 0);
		}
	}

	/**
		Builds the world-to-clip matrix for drawing into the view's tile, from its rows.
		x = 2 u_num - w and y = w - 2 v_num, where u_num and v_num are the ROW_U and
		ROW_V dot products. z is linear for an orthographic view. For a perspective
		view it is the usual perspective depth over [near, far], and the casters then
		write the linear depth themselves (see drawCasters()).
	**/
	static function setClipMatrix(view: Int) {
		var v = views;
		var o = viewOffset(view);
		var u = o + ROW_U, vRow = o + ROW_V, d = o + ROW_DEPTH, w = o + ROW_W;
		var zx, zy, zz, zw;
		if (isPerspective(o)) {
			var near = v[o + NEAR], far = v[o + NEAR] + v[o + DEPTH_RANGE];
			var a = (far + near) / (far - near), b = -2 * far * near / (far - near);
			zx = a * v[w]; zy = a * v[w + 1]; zz = a * v[w + 2]; zw = a * v[w + 3] + b;
		}
		else {
			zx = 2 * v[d]; zy = 2 * v[d + 1]; zz = 2 * v[d + 2]; zw = 2 * v[d + 3] - 1;
		}
		var m = clipMatrices[view];
		m._00 = 2 * v[u] - v[w]; m._10 = 2 * v[u + 1] - v[w + 1]; m._20 = 2 * v[u + 2] - v[w + 2]; m._30 = 2 * v[u + 3] - v[w + 3];
		m._01 = v[w] - 2 * v[vRow]; m._11 = v[w + 1] - 2 * v[vRow + 1];
		m._21 = v[w + 2] - 2 * v[vRow + 2]; m._31 = v[w + 3] - 2 * v[vRow + 3];
		m._02 = zx; m._12 = zy; m._22 = zz; m._32 = zw;
		m._03 = v[w]; m._13 = v[w + 1]; m._23 = v[w + 2]; m._33 = v[w + 3];
	}

	static inline function viewOffset(view: Int): Int {
		return view * VIEW_VEC4S * 4;
	}

	static inline function isPerspective(o: Int): Bool {
		return views[o + PERSPECTIVE] > 0.5;
	}

	static inline function setRow(o: Int, x: Float, y: Float, z: Float, w: Float) {
		views[o] = x; views[o + 1] = y; views[o + 2] = z; views[o + 3] = w;
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

	/** The largest atlas side: the largest power of two whose depth and R32 texels fit in Eevee's pool size. **/
	static function poolAtlas(): Int {
		var bytes = RasterSettings.shadowPoolSize * 1024.0 * 1024.0;
		var size = MIN_ATLAS;
		while (size * 2 <= MAX_ATLAS && (size * 2.0) * (size * 2.0) * 8 <= bytes) size *= 2;
		return size;
	}

	/**
		Makes sure the atlas has side `size`. It is made again at once when it must
		grow, or when the pool shrank below it. It shrinks only after SHRINK_FRAMES
		frames in a row of needing less.
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
