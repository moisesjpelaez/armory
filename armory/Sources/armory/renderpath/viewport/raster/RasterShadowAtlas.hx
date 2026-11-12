package armory.renderpath.viewport.raster;

import iron.RenderPath;

/**
	The shadow atlas: one square depth image that holds every shadow view's tile.

	Each frame, the views say how many texels they ask for (`needs`). resize()
	then picks the smallest atlas that holds them all, up to the largest that
	Eevee's shadow_pool_size allows (poolSide()). pack() gives each view its
	square tile (`tiles`). When the views do not fit the largest atlas, all of them
	shrink by the same factor.

	The image is made again when the atlas must grow. It shrinks only after
	needing less for a while, so zooming back and forth does not remake it.
	(RasterShadows.render() calls resize(), then pack().)
**/
class RasterShadowAtlas {

	public static inline var TARGET = "vpraster_shadow_atlas";
	static inline var MIN_ATLAS = 256;
	static inline var MAX_ATLAS = 4096;
	static inline var MIN_TILE = 128;
	static inline var TILE_STEP = 64; // tile sizes are multiples of this (texels), so they change less often while zooming
	/** Frames a smaller atlas must be enough for before the atlas shrinks, so zooming back and forth does not remake it. **/
	static inline var SHRINK_FRAMES = 120;
	/** Halvings in the search for the shrink factor (pack()). Enough to come within a thousandth of the largest that fits. **/
	static inline var SHRINK_STEPS = 10;
	/** Bytes an atlas texel takes of Eevee's pool: its depth and its R32 colour. **/
	static inline var TEXEL_BYTES = 8;

	/** Per view: the texels (tile side) it asks for this frame. The views write it before resize(). **/
	public static var needs = [for (_ in 0...RasterShadows.MAX_VIEWS) 0.0];
	/** Per view: its tile's x, y and size in texels. The size is 0 when the tile found no room. **/
	public static var tiles = [for (_ in 0...RasterShadows.MAX_VIEWS) [0, 0, 0]];
	/** The atlas's side in texels. **/
	public static var size = 0;
	public static var target: iron.RenderPath.RenderTarget = null;
	public static var image(get, never): kha.Image;

	static var order = [for (_ in 0...RasterShadows.MAX_VIEWS) 0]; // views by size, largest first (packTiles())
	static var shrinkFrames = 0;

	static function get_image(): kha.Image {
		return target != null ? target.image : null;
	}

	/** The largest atlas side: the largest power of two whose depth and R32 texels fit in Eevee's pool size. **/
	public static function poolSide(): Int {
		var bytes = RasterSettings.current.shadow_pool_size * 1024.0 * 1024.0;
		var side = MIN_ATLAS;
		while (side * 2 <= MAX_ATLAS && (side * 2.0) * (side * 2.0) * TEXEL_BYTES <= bytes) side *= 2;
		return side;
	}

	/**
		Makes the atlas the smallest that holds the first `count` views at the size
		each asks for. If none does, it is the largest atlas (`pool`, from poolSide()).
	**/
	public static function resize(path: RenderPath, count: Int, pool: Int) {
		var side = MIN_ATLAS;
		while (side < pool && !packTiles(count, side, 1.0)) side *= 2;
		ensure(path, side, pool);
	}

	/**
		Gives each of the first `count` views its tile in the atlas. When they do not
		fit at the sizes they ask for, all shrink by the largest factor that fits.
	**/
	public static function pack(count: Int) {
		if (packTiles(count, size, 1.0)) return;
		// Bisection for the largest shrink factor that fits
		var fits = 0.0, fails = 1.0;
		for (_ in 0...SHRINK_STEPS) {
			var scale = (fits + fails) / 2;
			if (packTiles(count, size, scale)) { fits = scale; } else { fails = scale; }
		}
		packTiles(count, size, fits); // views that still find no room get an empty tile
	}

	/**
		Packs the views' square tiles into a `side` x `side` atlas, in shelves, largest
		first. Each tile's size is its view's need times `scale`, rounded up to
		TILE_STEP texels. Returns whether all fit. The ones that do not fit get an
		empty tile.
	**/
	static function packTiles(count: Int, side: Int, scale: Float): Bool {
		for (view in 0...count) {
			// Not clamped to `side`: a tile larger than the atlas must fail to fit
			var tile = Math.ceil(needs[view] * scale / TILE_STEP) * TILE_STEP;
			tiles[view][2] = Std.int(Math.max(tile, MIN_TILE));
			// Insertion sort into `order`, largest first. It allocates nothing, as this runs every frame.
			var i = view;
			while (i > 0 && tiles[order[i - 1]][2] < tiles[view][2]) {
				order[i] = order[i - 1];
				i--;
			}
			order[i] = view;
		}
		var x = 0, y = 0, shelf = 0, all = true;
		for (i in 0...count) {
			var view = order[i];
			var tile = tiles[view][2];
			if (x + tile > side) { // start the next shelf. Each shelf is as tall as its first (largest) tile.
				x = 0;
				y += shelf;
				shelf = 0;
			}
			if (y + tile > side) {
				tiles[view][2] = 0;
				all = false;
				continue;
			}
			tiles[view][0] = x;
			tiles[view][1] = y;
			x += tile;
			if (shelf == 0) shelf = tile;
		}
		return all;
	}

	/**
		Makes sure the atlas has side `side`. It is made again at once when it must
		grow, or when the pool shrank below it. It shrinks only after SHRINK_FRAMES
		frames in a row of needing less.
	**/
	static function ensure(path: RenderPath, side: Int, pool: Int) {
		if (target != null) {
			if (side == size || (side < size && size <= pool && ++shrinkFrames < SHRINK_FRAMES)) {
				if (side == size) shrinkFrames = 0;
				return;
			}
			target.image.unload();
		}
		shrinkFrames = 0;
		var raw = new iron.RenderPath.RenderTargetRaw();
		raw.name = TARGET;
		raw.width = side;
		raw.height = side;
		raw.format = "R32";
		target = new iron.RenderPath.RenderTarget(raw);
		target.image = kha.Image.createRenderTarget(side, side, kha.graphics4.TextureFormat.A32,
			kha.graphics4.DepthStencilFormat.DepthOnly);
		path.renderTargets.set(TARGET, target);
		size = side;
	}
}
