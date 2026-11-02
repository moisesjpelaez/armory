package armory.renderpath.eevee;

import iron.Scene;

/**
	Packs the scene's lights each frame into the layout the MaterialX shaders
	unpack (blender/arm/eevee/glsl_rewrite.py), LIGHT_VEC4S vec4 per light:
	  0: type, kind, spot_size, spot_blend
	  1: position.xyz, energy
	  2: direction.xyz (where the light travels), unused
	  3: color.rgb, unused
	kind follows Blender: 0 sun, 1 point, 2 spot. Area lights are drawn as
	point lights of the same power for now.
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
			data[o + 11] = 0.0;
			data[o + 12] = raw.color[0];
			data[o + 13] = raw.color[1];
			data[o + 14] = raw.color[2];
			data[o + 15] = 0.0;
			count++;
		}
		EeveeUniforms.lightCount = count;
	}
}
