package armory.renderpath.viewport.raster;

import iron.Scene;

/**
	Packs the scene's lights into `RasterUniforms.lights` every frame, for the
	lighting pass to read (`arm_get_light()` in Shaders/vpraster/vpraster_lights.glsl).

	Each light takes LIGHT_VEC4S (6) vec4, in this order:
	  0: kind, spot size, spot blend, number of shadow views
	  1: position, energy
	  2: direction (where the light travels), influence radius (0 = none)
	  3: color, first shadow view (-1 = no shadow; see RasterShadows)
	  4: radius (sun: half angle; point, spot: metres), area width, area height,
	     area shape (1 = ellipse)
	  5: area light's local X axis, channel in the shadow pass's image (-1 = none)
	The offsets below name each float. Change them together with `arm_get_light()`.
**/
class RasterLights {

	// Light kinds, as Blender's. The shaders get them as ARM_LIGHT_SUN... (engine.py).
	public static inline var SUN = 0;
	public static inline var POINT = 1;
	public static inline var SPOT = 2;
	public static inline var AREA = 3;

	/** Most shadow-casting lights the shadow pass draws: one channel each of an RGBA image. **/
	public static inline var PASS_LIGHTS = 4;

	/**
		Smallest sun half angle (radians) drawn as a disc in highlights. Smaller suns
		are points. The shaders get it as ARM_MIN_OUTLINE_ANGLE (engine.py).
	**/
	public static inline var MIN_OUTLINE_ANGLE = 0.005;

	// Offsets of each value in a light's floats (see the layout above)
	static inline var KIND = 0;
	static inline var SPOT_SIZE = 1;
	static inline var SPOT_BLEND = 2;
	static inline var SHADOW_VIEW_COUNT = 3;
	static inline var POSITION = 4;
	static inline var ENERGY = 7;
	static inline var DIRECTION = 8;
	static inline var INFLUENCE_RADIUS = 11;
	static inline var COLOR = 12;
	static inline var FIRST_SHADOW_VIEW = 15;
	static inline var RADIUS = 16;
	static inline var AREA_SIZE = 17;
	static inline var AREA_SHAPE = 19;
	static inline var TANGENT = 20;
	static inline var SHADOW_CHANNEL = 23;

	/**
		Whether any lamp may need its outline this frame. If none does, the renderer
		uses the lighting pass version without outline code (RenderPathViewportRaster).
	**/
	public static var outlines(default, null) = false;

	/**
		Whether any spot, point or area light casts a shadow this frame. If none does,
		the lighting and shadow passes use versions without the code for perspective views.
	**/
	public static var localShadows(default, null) = false;

	/**
		Number of shadow-casting lights this frame. Up to PASS_LIGHTS, the shadow pass
		draws them and the lighting pass reads the result. With more, the lighting
		pass looks every shadow up itself.
	**/
	public static var shadowLights(default, null) = 0;

	/**
		Packs up to MAX_LIGHTS visible lights, then the world's sun, and asks
		RasterShadows for each light's shadow views. The renderer calls it first in every frame.
	**/
	public static function update() {
		var data = RasterUniforms.lights;
		var count = 0;
		outlines = false;
		localShadows = false;
		RasterShadows.begin();
		for (light in Scene.active.lights) {
			if (!light.visible || count == RasterUniforms.MAX_LIGHTS) continue;
			var raw = light.data.raw;
			var kind = switch (raw.type) {
				case "sun": SUN;
				case "spot": SPOT;
				case "area": AREA;
				default: POINT;
			}
			var m = light.transform.world;
			// Blender lights shine along their local -Z axis
			var dx = -m._20, dy = -m._21, dz = -m._22;
			var length = Math.sqrt(dx * dx + dy * dy + dz * dz);
			if (length > 0) {
				dx /= length;
				dy /= length;
				dz /= length;
			}

			var o = offset(count);
			data[o + KIND] = kind;
			data[o + SPOT_SIZE] = kind == SPOT ? raw.spot_size : 0.0;
			data[o + SPOT_BLEND] = kind == SPOT ? raw.spot_blend : 0.0;
			setVec3(o + POSITION, m._30, m._31, m._32);
			data[o + ENERGY] = raw.strength;
			setVec3(o + DIRECTION, dx, dy, dz);
			data[o + INFLUENCE_RADIUS] = kind == SUN ? 0.0 : influenceRadius(raw);
			setVec3(o + COLOR, raw.color[0], raw.color[1], raw.color[2]);

			var firstView = -1;
			if (raw.cast_shadow) {
				firstView = kind == SUN ? RasterShadows.addSun(dx, dy, dz)
					: RasterShadows.addLocal(kind == SPOT, m._30, m._31, m._32, dx, dy, dz, raw.spot_size, influenceRadius(raw));
			}
			setShadowViews(o, firstView);
			if (kind != SUN && firstView >= 0) localShadows = true;

			// Light size: [radius, area width, area height, area shape] (blender/arm/viewport/raster/lights.py)
			var size = raw.vpraster_size;
			data[o + RADIUS] = size != null ? size[0] : 0.0;
			data[o + AREA_SIZE] = size != null ? size[1] : 0.0;
			data[o + AREA_SIZE + 1] = size != null ? size[2] : 0.0;
			data[o + AREA_SHAPE] = size != null ? size[3] : 0.0;
			if (needsOutline(kind, data[o + RADIUS])) outlines = true;

			// Local X axis: the area light's width direction
			var tx = m._00, ty = m._01, tz = m._02;
			var tl = Math.sqrt(tx * tx + ty * ty + tz * tz);
			setVec3(o + TANGENT, tx / tl, ty / tl, tz / tl);
			count++;
		}
		count = packWorldSun(count);
		RasterUniforms.lightCount = count;
		assignShadowChannels(count);
	}

	/**
		Packs the world's sun, if it has one: the light above a brightness threshold,
		cut out of the world image by the export (blender/arm/viewport/raster/world.py).
		Returns the new light count.
	**/
	static function packWorldSun(count: Int): Int {
		var world = Scene.active.world;
		if (world == null || count == RasterUniforms.MAX_LIGHTS) return count;
		var sun = world.raw.vpraster_sun;
		if (sun == null) return count;
		var data = RasterUniforms.lights;
		var o = offset(count);
		for (i in 0...RasterUniforms.LIGHT_VEC4S * 4) data[o + i] = 0.0;
		data[o + KIND] = SUN;
		data[o + ENERGY] = sun.strength;
		setVec3(o + DIRECTION, sun.direction[0], sun.direction[1], sun.direction[2]);
		setVec3(o + COLOR, sun.color[0], sun.color[1], sun.color[2]);
		setShadowViews(o, sun.shadow ? RasterShadows.addSun(sun.direction[0], sun.direction[1], sun.direction[2]) : -1);
		data[o + RADIUS] = sun.angle * 0.5;
		if (needsOutline(SUN, data[o + RADIUS])) outlines = true;
		return count + 1;
	}

	/**
		Gives the first PASS_LIGHTS shadow-casting lights a channel of the shadow pass's
		image, in light order. The others get none.
	**/
	static function assignShadowChannels(count: Int) {
		var data = RasterUniforms.lights;
		shadowLights = 0;
		for (i in 0...count) {
			var o = offset(i);
			var casts = data[o + FIRST_SHADOW_VIEW] >= 0;
			data[o + SHADOW_CHANNEL] = casts && shadowLights < PASS_LIGHTS ? shadowLights : -1;
			if (casts) shadowLights++;
		}
	}

	static inline function offset(light: Int): Int {
		return light * RasterUniforms.LIGHT_VEC4S * 4;
	}

	static inline function setVec3(o: Int, x: Float, y: Float, z: Float) {
		var data = RasterUniforms.lights;
		data[o] = x;
		data[o + 1] = y;
		data[o + 2] = z;
	}

	/** The light's first shadow view (-1 for none) and how many it has. **/
	static function setShadowViews(o: Int, firstView: Int) {
		var data = RasterUniforms.lights;
		data[o + FIRST_SHADOW_VIEW] = firstView;
		data[o + SHADOW_VIEW_COUNT] = firstView < 0 ? 0 : RasterShadows.viewsAt(firstView);
	}

	/**
		Whether the lighting pass may draw a lamp by its outline:
		- area lights always;
		- suns from MIN_OUTLINE_ANGLE (allowing a little below, for float rounding);
		- point and spot lights with any radius above 0.
		A NaN radius counts as an outline.
	**/
	static function needsOutline(kind: Int, radius: Float): Bool {
		return switch (kind) {
			case AREA: true;
			case SUN: !(radius < MIN_OUTLINE_ANGLE * 0.98);
			default: !(radius <= 0.0);
		}
	}

	/**
		How far a point, spot or area light reaches (0 = no limit). It is the light's
		Custom Distance if set. Otherwise, as in Eevee, it is where the light falls
		below the scene's Light Threshold: 0.1 * sqrt(power * brightest colour channel / threshold).
	**/
	static function influenceRadius(raw: iron.data.SceneFormat.TLightData): Float {
		if (raw.cutoff_distance != null) return raw.cutoff_distance;
		var threshold = RasterSettings.current.light_threshold;
		if (threshold <= 0) return 0.0;
		var peak = Math.max(raw.color[0], Math.max(raw.color[1], raw.color[2]));
		return 0.1 * Math.sqrt(raw.strength * peak / threshold);
	}
}
