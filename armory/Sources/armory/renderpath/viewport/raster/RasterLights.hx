package armory.renderpath.viewport.raster;

import iron.Scene;

/**
	Packs the scene's lights each frame into the layout the lighting pass
	unpacks (Shaders/vpraster/vpraster_lights.glsl), 6 vec4 per light:
	  0: kind, spot_size, spot_blend, unused
	  1: position.xyz, energy
	  2: direction.xyz (where the light travels), cutoff (influence radius, 0 = none)
	  3: color.rgb, first shadow view (-1 = none, see RasterShadows)
	  4: radius (sun: half angle, point/spot: metres), size_x, size_y, shape (area)
	  5: tangent.xyz (area: the light's local X axis), unused
	kind follows Blender: 0 sun, 1 point, 2 spot, 3 area (one-sided emitter).
**/
class RasterLights {

	/**
		Whether a lamp may need its outline this frame (vpraster_lights.glsl: lamps
		with a size); without one the lighting pass is drawn with the outline code
		compiled out (RenderPathViewportRaster, lighting.py).
	**/
	public static var outlines(default, null) = false;
	/**
		Whether a spot, point or area light casts a shadow this frame; without one the
		lighting pass is drawn with the perspective shadow code compiled out.
	**/
	public static var localShadows(default, null) = false;

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
				case "sun": 0;
				case "spot": 2;
				case "area": 3;
				default: 1;
			}
			var m = light.transform.world;
			// Blender lights shine along their local -Z axis
			var dx = -m._20, dy = -m._21, dz = -m._22;
			var length = Math.sqrt(dx * dx + dy * dy + dz * dz);
			if (length > 0) { dx /= length; dy /= length; dz /= length; }

			var o = count * RasterUniforms.LIGHT_VEC4S * 4;
			data[o + 0] = kind;
			data[o + 1] = kind == 2 ? raw.spot_size : 0.0;
			data[o + 2] = kind == 2 ? raw.spot_blend : 0.0;
			data[o + 3] = 0.0; // shadow views, below
			data[o + 4] = m._30;
			data[o + 5] = m._31;
			data[o + 6] = m._32;
			data[o + 7] = raw.strength;
			data[o + 8] = dx;
			data[o + 9] = dy;
			data[o + 10] = dz;
			data[o + 11] = kind == 0 ? 0.0 : cutoff(raw);
			data[o + 12] = raw.color[0];
			data[o + 13] = raw.color[1];
			data[o + 14] = raw.color[2];
			data[o + 15] = !raw.cast_shadow ? -1 : kind == 0 ? RasterShadows.addSun(dx, dy, dz)
				: RasterShadows.addLocal(kind == 2, m._30, m._31, m._32, dx, dy, dz, raw.spot_size, cutoff(raw));
			data[o + 3] = data[o + 15] < 0 ? 0 : RasterShadows.viewsAt(Std.int(data[o + 15]));
			if (kind != 0 && data[o + 15] >= 0) localShadows = true;
			var size: Dynamic = Reflect.field(raw, "vpraster_size");
			for (i in 0...4) data[o + 16 + i] = component(size, i);
			if (needsOutline(kind, data[o + 16])) outlines = true;
			// Local X axis (area lights' width direction)
			var tx = m._00, ty = m._01, tz = m._02;
			var tl = Math.sqrt(tx * tx + ty * ty + tz * tz);
			data[o + 20] = tx / tl;
			data[o + 21] = ty / tl;
			data[o + 22] = tz / tl;
			data[o + 23] = 0.0;
			count++;
		}
		count = packWorldSun(count);
		RasterUniforms.lightCount = count;
	}

	/** The sun extracted from the world's brightest light (blender/arm/viewport/world.py), if any. **/
	static function packWorldSun(count: Int): Int {
		var world = Scene.active.world;
		if (world == null || count == RasterUniforms.MAX_LIGHTS) return count;
		var sun: Dynamic = Reflect.field(world.raw, "vpraster_sun");
		if (sun == null) return count;
		var data = RasterUniforms.lights;
		var o = count * RasterUniforms.LIGHT_VEC4S * 4;
		for (i in 0...RasterUniforms.LIGHT_VEC4S * 4) data[o + i] = 0.0;
		data[o + 0] = 0; // sun
		data[o + 7] = sun.strength;
		data[o + 8] = component(sun.direction, 0);
		data[o + 9] = component(sun.direction, 1);
		data[o + 10] = component(sun.direction, 2);
		data[o + 12] = component(sun.color, 0);
		data[o + 13] = component(sun.color, 1);
		data[o + 14] = component(sun.color, 2);
		data[o + 15] = sun.shadow == true ? RasterShadows.addSun(data[o + 8], data[o + 9], data[o + 10]) : -1;
		data[o + 3] = data[o + 15] < 0 ? 0 : RasterShadows.viewsAt(Std.int(data[o + 15]));
		data[o + 16] = sun.angle * 0.5;
		if (needsOutline(0, data[o + 16])) outlines = true;
		return count + 1;
	}

	/**
		Whether the lighting pass may draw a lamp of `kind` and `radius` by its outline:
		area lights always; suns of 0.005 rad (half angle) or more, a little below for
		float rounding; point and spot lights with any radius (an outline within about
		200 radii of the light). Unknown radii count as outlines.
	**/
	static function needsOutline(kind: Int, radius: Float): Bool {
		return switch (kind) {
			case 3: true;
			case 0: !(radius < 0.0049);
			default: !(radius <= 0.0);
		}
	}

	/** Packed .arm data stores float lists as Float32Array, JSON as plain arrays. **/
	static function component(values: Dynamic, index: Int): Float {
		if (Std.isOfType(values, Array)) return values[index];
		var typed: kha.arrays.Float32Array = values;
		return typed[index];
	}

	/**
		Influence radius: the light's custom distance, or where it falls below
		Eevee's light_threshold. Measured on Eevee: 0.1 * sqrt(power / threshold),
		power scaled by the brightest colour channel.
	**/
	static function cutoff(raw: iron.data.SceneFormat.TLightData): Float {
		var custom: Null<Float> = Reflect.field(raw, "cutoff_distance");
		if (custom != null) return custom;
		var threshold = RasterSettings.lightThreshold;
		if (threshold <= 0) return 0.0;
		var peak = Math.max(raw.color[0], Math.max(raw.color[1], raw.color[2]));
		return 0.1 * Math.sqrt(raw.strength * peak / threshold);
	}
}
