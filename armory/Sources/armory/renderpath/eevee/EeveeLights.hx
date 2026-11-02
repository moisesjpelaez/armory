package armory.renderpath.eevee;

import iron.Scene;

/**
	Packs the scene's lights each frame into the layout the MaterialX shaders
	unpack (blender/arm/eevee/glsl_rewrite.py), LIGHT_VEC4S vec4 per light:
	  0: type, kind, spot_size, spot_blend
	  1: position.xyz, energy
	  2: direction.xyz (where the light travels), cutoff (influence radius, 0 = none)
	  3: color.rgb, unused
	kind follows Blender: 0 sun, 1 point, 2 spot, 3 area (a small one-sided
	emitter for now; its size is not modelled yet).
**/
class EeveeLights {

	// MaterialX type id of the universal Blender light (Shaders/eevee/materialx/arm_lights.mtlx)
	static inline var LIGHT_TYPE = 1;

	public static function update() {
		var data = EeveeUniforms.lights;
		var count = 0;
		for (light in Scene.active.lights) {
			if (!light.visible || count == EeveeUniforms.MAX_LIGHTS) continue;
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

			var o = count * EeveeUniforms.LIGHT_VEC4S * 4;
			data[o + 0] = LIGHT_TYPE;
			data[o + 1] = kind;
			data[o + 2] = kind == 2 ? raw.spot_size : 0.0;
			data[o + 3] = kind == 2 ? raw.spot_blend : 0.0;
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
			data[o + 15] = 0.0;
			count++;
		}
		count = packWorldSun(count);
		EeveeUniforms.lightCount = count;
	}

	/** The sun extracted from the world's brightest light (blender/arm/eevee/world.py), if any. **/
	static function packWorldSun(count: Int): Int {
		var world = Scene.active.world;
		if (world == null || count == EeveeUniforms.MAX_LIGHTS) return count;
		var sun: Dynamic = Reflect.field(world.raw, "eevee_sun");
		if (sun == null) return count;
		var data = EeveeUniforms.lights;
		var o = count * EeveeUniforms.LIGHT_VEC4S * 4;
		for (i in 0...16) data[o + i] = 0.0;
		data[o + 0] = LIGHT_TYPE;
		data[o + 1] = 0; // sun
		data[o + 7] = sun.strength;
		data[o + 8] = component(sun.direction, 0);
		data[o + 9] = component(sun.direction, 1);
		data[o + 10] = component(sun.direction, 2);
		data[o + 12] = component(sun.color, 0);
		data[o + 13] = component(sun.color, 1);
		data[o + 14] = component(sun.color, 2);
		return count + 1;
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
		var threshold = EeveeSettings.lightThreshold;
		if (threshold <= 0) return 0.0;
		var peak = Math.max(raw.color[0], Math.max(raw.color[1], raw.color[2]));
		return 0.1 * Math.sqrt(raw.strength * peak / threshold);
	}
}
