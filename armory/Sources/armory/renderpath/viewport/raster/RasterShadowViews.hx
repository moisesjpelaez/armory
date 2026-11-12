package armory.renderpath.viewport.raster;

import kha.arrays.Float32Array;
import iron.math.Mat4;
import iron.math.Vec4;

/**
	This frame's shadow views: what the shaders read to look a shadow up, and the
	matrix that draws each view's tile. A light's views follow each other, and
	`groups` holds how many it has.

	A sun's views are orthographic (RasterShadowSuns writes them). A spot light
	gets one perspective view over its cone. Point and area lights get the six
	faces of a cube, slightly widened so filtering never runs off a face
	(addLocal() writes both).

	The shaders read the views from `data` (`arm_shadow_view()` in
	Shaders/vpraster/vpraster_lights.glsl). Each view takes
	RasterShadows.VIEW_VEC4S (6) vec4, the rows named below:
	  ROW_U, ROW_V: dot one with a world position (1 in w) and divide by ROW_W's to get
	                the tile coordinates u and v (0..1, v down)
	  ROW_DEPTH:    the same for the linear depth (0..1 over the view's depth range)
	  ROW_W:        the divisor w (orthographic views: 0, 0, 0, 1)
	  ROW_TILE:     the tile in the atlas: x, y, width, height (upside down where render
	                targets are; see placeInAtlas())
	  ROW_EXTRA:    tile uv per metre at w = 1, near distance, depth range (metres),
	                1 for a perspective view
**/
class RasterShadowViews {

	// Offsets of each row in a view's floats (see the layout above)
	public static inline var ROW_U = 0;
	public static inline var ROW_V = 4;
	public static inline var ROW_DEPTH = 8;
	public static inline var ROW_W = 12;
	public static inline var ROW_TILE = 16;
	public static inline var ROW_EXTRA = 20;
	// The values of ROW_EXTRA
	public static inline var UV_PER_METRE = ROW_EXTRA;
	public static inline var NEAR = ROW_EXTRA + 1;
	public static inline var DEPTH_RANGE = ROW_EXTRA + 2;
	public static inline var PERSPECTIVE = ROW_EXTRA + 3;

	// The kinds of view (`kinds`)
	public static inline var SUN_VIEW = 0;
	public static inline var SPOT_VIEW = 1;
	public static inline var CUBE_VIEW = 2;

	static inline var CUBE_WIDEN = 1.1; // tan of a cube face's half angle: 45 degrees plus a margin
	static inline var LOCAL_NEAR = 0.05;
	static inline var LOCAL_FAR = 100.0; // for lights without an influence radius
	/** Added to a spot's half angle (radians), so filtering never runs off the cone's edge. **/
	static inline var SPOT_MARGIN = 0.1;
	/** The widest half angle of a spot's view (radians). It stays below a right angle, where the tangent grows without limit. **/
	static inline var SPOT_MAX_HALF_ANGLE = 1.45;
	// A spot view's tile is the largest atlas's side divided by this, and a cube face's likewise
	static inline var SPOT_TILE_DIVISOR = 4;
	static inline var CUBE_TILE_DIVISOR = 8;
	/**
		A direction whose z is beyond this (either way) counts as parallel to world Z.
		Its basis then takes world Y as up: a cross product with world Z would be
		too short to give a direction (lightBasis()).
	**/
	static inline var PARALLEL_LIMIT = 0.99;
	// Cube face directions (x, y, z per face)
	static var CUBE_FACES = [1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0];

	/** The views' floats, as the shaders read them (see the layout above). **/
	public static var data = new Float32Array(RasterShadows.MAX_VIEWS * RasterShadows.VIEW_VEC4S * 4);
	/** The number of views this frame. **/
	public static var count = 0;
	/** Per view: SUN_VIEW, SPOT_VIEW or CUBE_VIEW. **/
	public static var kinds = [for (_ in 0...RasterShadows.MAX_VIEWS) SUN_VIEW];
	/** At a light's first view: how many views it has. **/
	public static var groups = [for (_ in 0...RasterShadows.MAX_VIEWS) 0];
	/** Per view: the world-to-clip matrix for drawing into its tile (setClipMatrix()). **/
	public static var clipMatrices = [for (_ in 0...RasterShadows.MAX_VIEWS) Mat4.identity()];

	// The basis of the view being written (setPerspective())
	static var viewRight = new Vec4();
	static var viewUp = new Vec4();

	/** Starts a frame. Drops the previous frame's views. **/
	public static function begin() {
		count = 0;
	}

	/**
		Takes the next `views` views for one light, all of `kind`. Returns the first
		one's index, or -1 when RasterShadows.MAX_VIEWS would be passed.
	**/
	public static function reserve(views: Int, kind: Int): Int {
		if (count + views > RasterShadows.MAX_VIEWS) return -1;
		var first = count;
		count += views;
		for (i in 0...views) kinds[first + i] = kind;
		groups[first] = views;
		return first;
	}

	/** Adds the views of a spot, point or area light (see RasterShadows.addLocal()). **/
	public static function addLocal(spot: Bool, px: Float, py: Float, pz: Float,
			dx: Float, dy: Float, dz: Float, spotSize: Float, range: Float): Int {
		if (!RasterSettings.current.use_shadows) return -1;
		var first = reserve(spot ? 1 : 6, spot ? SPOT_VIEW : CUBE_VIEW);
		if (first < 0) return -1;
		var far = range > 0 ? range : LOCAL_FAR;
		if (spot) {
			var halfTan = Math.tan(Math.min(spotSize * 0.5 + SPOT_MARGIN, SPOT_MAX_HALF_ANGLE));
			setPerspective(first, px, py, pz, dx, dy, dz, halfTan, far);
		}
		else {
			for (i in 0...6) setPerspective(first + i, px, py, pz, CUBE_FACES[i * 3], CUBE_FACES[i * 3 + 1], CUBE_FACES[i * 3 + 2], CUBE_WIDEN, far);
		}
		return first;
	}

	/**
		Asks the atlas for the tiles of the spot and cube views: fixed fractions of the
		largest atlas's side (`pool`). The sun views ask for theirs in RasterShadowSuns.fit().
	**/
	public static function sizeLocal(pool: Int) {
		for (view in 0...count) {
			switch (kinds[view]) {
				case SPOT_VIEW: RasterShadowAtlas.needs[view] = pool / SPOT_TILE_DIVISOR;
				case CUBE_VIEW: RasterShadowAtlas.needs[view] = pool / CUBE_TILE_DIVISOR;
				default:
			}
		}
	}

	/**
		The basis across a light that shines along the unit vector (dx, dy, dz), into
		`right` and `up`. Up is world Z, or world Y when the light shines along Z
		(PARALLEL_LIMIT). Looking along the light with `up` upwards, `right` points right.
	**/
	public static function lightBasis(dx: Float, dy: Float, dz: Float, right: Vec4, up: Vec4) {
		var ux = 0.0, uy = 0.0, uz = 1.0;
		if (Math.abs(dz) > PARALLEL_LIMIT) { ux = 0.0; uy = 1.0; uz = 0.0; }
		var rx = dy * uz - dz * uy, ry = dz * ux - dx * uz, rz = dx * uy - dy * ux;
		var rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
		rx /= rl; ry /= rl; rz /= rl;
		right.set(rx, ry, rz);
		up.set(ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx);
	}

	/** Writes a perspective view from (px, py, pz) along (fx, fy, fz), with `halfTan` = tan(half angle). **/
	static function setPerspective(view: Int, px: Float, py: Float, pz: Float,
			fx: Float, fy: Float, fz: Float, halfTan: Float, far: Float) {
		lightBasis(fx, fy, fz, viewRight, viewUp);
		var rx = viewRight.x, ry = viewRight.y, rz = viewRight.z;
		var ux = viewUp.x, uy = viewUp.y, uz = viewUp.z;
		var k = 0.5 / halfTan;
		var range = far - LOCAL_NEAR;
		var o = offset(view);
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
		Writes every view's tile (ROW_TILE) and clip matrix, once the atlas has packed
		the tiles (RasterShadowAtlas.pack()).

		Tiles are drawn the same way on every backend (setClipMatrix()). Where render
		targets are upside down (OpenGL, WebGL), so are a tile's rows. So its
		rectangle starts at its other edge with a negative height, and the shaders'
		lookups (rect.xy + uv * rect.zw) mirror within the tile. Flipping the
		projection instead would also reverse the triangles' winding, and with it
		which faces the shadow pass culls.
	**/
	public static function placeInAtlas() {
		var mirrored = kha.Image.renderTargetsInvertedY();
		var atlasSize = RasterShadowAtlas.size;
		for (view in 0...count) {
			var o = offset(view) + ROW_TILE;
			var t = RasterShadowAtlas.tiles[view];
			var size = t[2] / atlasSize;
			if (mirrored) setRow(o, t[0] / atlasSize, t[1] / atlasSize + size, size, -size);
			else setRow(o, t[0] / atlasSize, t[1] / atlasSize, size, size);
			setClipMatrix(view);
		}
	}

	/**
		Builds the world-to-clip matrix for drawing into the view's tile, from its rows.
		x = 2 u_num - w and y = w - 2 v_num, where u_num and v_num are the ROW_U and
		ROW_V dot products. z is linear for an orthographic view. For a perspective
		view it is the usual perspective depth over [near, far], and the casters then
		write the linear depth themselves (see RasterShadowCasters.draw()).
	**/
	static function setClipMatrix(view: Int) {
		var v = data;
		var o = offset(view);
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

	/** Where view `view`'s floats start in `data`. **/
	public static inline function offset(view: Int): Int {
		return view * RasterShadows.VIEW_VEC4S * 4;
	}

	/** Whether the view whose floats start at `o` is a perspective one. **/
	public static inline function isPerspective(o: Int): Bool {
		return data[o + PERSPECTIVE] > 0.5;
	}

	/** Writes one row (a vec4) at float `o` of `data`. **/
	public static inline function setRow(o: Int, x: Float, y: Float, z: Float, w: Float) {
		data[o] = x; data[o + 1] = y; data[o + 2] = z; data[o + 3] = w;
	}
}
