package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import kha.arrays.Float32Array;
import iron.RenderPath;
import iron.math.Mat4;
import iron.math.Vec4;

/**
	Shadow maps for the Viewport renderer. All shadow views share one depth atlas,
	just big enough for this frame's views. Eevee's shadow_pool_size sets its
	largest size. Each frame, the lights ask for views while RasterLights packs
	them (addSun(), addLocal()). Then render() sizes the views, packs them into the
	atlas and draws the shadow casters into each view's tile.

	This class is the entry point. The work is in four classes:
	- RasterShadowViews: the views the shaders read (their layout is listed there),
	  and the views of spot, point and area lights.
	- RasterShadowSuns: the views of sun lights, fitted to the camera.
	- RasterShadowAtlas: the atlas image, and where each view's tile goes in it.
	- RasterShadowCasters: draws the meshes that cast a shadow into a view.

	Sun lights get orthographic views over the camera's depth range. Each has
	texels of about one screen pixel at its nearest point. As in Eevee, a hard
	shadow edge then has the same width in pixels at any zoom and render size.

	Spot lights get one perspective view over their cone. Point and area lights
	get the six faces of a cube. These views take fixed fractions of the largest
	atlas. When the views do not fit the largest atlas, all of them shrink by the
	same factor (RasterShadowAtlas.pack()).
**/
class RasterShadows {

	// The build reads these four for the shaders and shader data (blender/arm/viewport/raster/engine.py).
	// It finds them by name in this file, so they stay here, each a `static inline var`.
	public static inline var MAX_VIEWS = 32;
	/** The vec4 each view takes in `views` (see RasterShadowViews for the layout). **/
	public static inline var VIEW_VEC4S = 6;
	/** The casters' pass for orthographic views. **/
	public static inline var CONTEXT = "vpraster_shadow";
	/**
		The casters' pass for perspective views. It writes the linear depth itself
		(vpraster_shadow_perspective.frag.glsl). Iron finds a material's pass by name
		prefix, so neither pass name may start with the other.
	**/
	public static inline var PERSPECTIVE_CONTEXT = "vpraster_perspective_shadow";

	/** This frame's views, as the shaders read them (link _vprasterShadows; see RasterShadowViews). **/
	public static var views(get, never): Float32Array;
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

	static inline function get_views(): Float32Array {
		return RasterShadowViews.data;
	}

	static inline function get_atlas(): kha.Image {
		return RasterShadowAtlas.image;
	}

	/** Starts a frame. Drops the previous frame's views. **/
	public static function begin() {
		RasterShadowViews.begin();
		RasterShadowSuns.begin();
	}

	/** The number of views of the light whose first view is `first`. The shaders loop over them. **/
	public static inline function viewsAt(first: Int): Int {
		return RasterShadowViews.groups[first];
	}

	/**
		Adds the views of a sun whose light travels along the unit vector (dx, dy, dz).
		Returns the first view's index, or -1 when shadows are off or MAX_VIEWS is reached.
		The views are sized in render() and placed once the tiles are known.
	**/
	public static inline function addSun(dx: Float, dy: Float, dz: Float): Int {
		return RasterShadowSuns.add(dx, dy, dz);
	}

	/**
		Adds the views of a light at (px, py, pz) shining along (dx, dy, dz). A spot
		gets one view over its cone (`spotSize` is the full angle). A point or area
		light gets six cube faces. `range` is the light's influence radius (0 = none).
		Returns the first view's index, or -1 when shadows are off or MAX_VIEWS is reached.
	**/
	public static inline function addLocal(spot: Bool, px: Float, py: Float, pz: Float,
			dx: Float, dy: Float, dz: Float, spotSize: Float, range: Float): Int {
		return RasterShadowViews.addLocal(spot, px, py, pz, dx, dy, dz, spotSize, range);
	}

	/**
		Sizes this frame's views, packs them into the atlas and draws every view's
		shadow casters into its tile. The renderer calls it after RasterLights.update(),
		before the material pass.
	**/
	public static function render(path: RenderPath) {
		var hdr = path.renderTargets.get(RenderPathViewportRaster.HDR);
		var screenHeight = hdr != null && hdr.image != null ? hdr.image.height : iron.App.h();
		// View sizes: suns from the screen, local lights fixed
		var pool = RasterShadowAtlas.poolSide();
		RasterShadowSuns.fit(screenHeight, pool);
		RasterShadowViews.sizeLocal(pool);

		var count = RasterShadowViews.count;
		RasterShadowAtlas.resize(path, count, pool);
		var steps = RasterSettings.current.shadow_step_count;
		info.set(1.0 / RasterShadowAtlas.size, penumbraScale(steps), RasterTaa.noiseFrame(), penumbraScaleLocal(steps));
		if (count == 0) return;
		RasterShadowAtlas.pack(count);
		// Suns are placed once the tiles are known: their texel snapping needs the tile size
		RasterShadowSuns.place();
		RasterShadowViews.placeInAtlas();
		drawTiles(path);
	}

	/** Draws every view's shadow casters into its tile of the atlas. **/
	static function drawTiles(path: RenderPath) {
		ViewportTargets.setAlone(path, RasterShadowAtlas.TARGET);
		var g = path.currentG;
		// Depth only: the lighting pass reads the depth buffer, and the colour image is
		// never written. 1 means nothing is in the way.
		g.clear(null, 1.0);
		var views = RasterShadowViews.data;
		for (view in 0...RasterShadowViews.count) {
			var t = RasterShadowAtlas.tiles[view];
			g.viewport(t[0], t[1], t[2], t[2]);
			viewProjection.setFrom(RasterShadowViews.clipMatrices[view]);
			var o = RasterShadowViews.offset(view) + RasterShadowViews.ROW_DEPTH;
			depthRow.set(views[o], views[o + 1], views[o + 2], views[o + 3]);
			RasterShadowCasters.draw(g, view);
		}
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
}
