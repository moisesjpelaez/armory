package armory.renderpath.eevee;

import kha.arrays.Float32Array;
import iron.data.MaterialData;
import iron.math.Mat4;
import iron.object.Object;
import iron.object.Uniforms;

/**
	Values the MaterialX shaders read from the engine, registered through Iron's
	external uniform links. Lights are empty and the world is a flat grey
	placeholder until the light packer and the world bake are connected.
**/
class EeveeUniforms {

	// Must match MAX_LIGHT_SOURCES and LIGHT_VEC4S in blender/arm/eevee
	public static inline var MAX_LIGHTS = 8;
	public static inline var LIGHT_VEC4S = 4;

	public static var lights = new Float32Array(MAX_LIGHTS * LIGHT_VEC4S * 4);
	public static var lightCount = 0;

	public static var envRadiance: kha.Image = null;
	public static var envIrradiance: kha.Image = null;
	public static var envMips = 1;
	public static var envIntensity = 1.0;
	// MaterialX looks up its latlong maps Y-up; Blender is Z-up
	static var envMatrix = new Mat4(1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1);

	public static function register() {
		if (envRadiance == null) {
			envRadiance = flatColor(0.5);
			envIrradiance = envRadiance;
		}

		if (Uniforms.externalFloatsLinks == null) Uniforms.externalFloatsLinks = [];
		if (Uniforms.externalIntLinks == null) Uniforms.externalIntLinks = [];
		if (Uniforms.externalFloatLinks == null) Uniforms.externalFloatLinks = [];
		if (Uniforms.externalMat4Links == null) Uniforms.externalMat4Links = [];
		if (Uniforms.externalTextureLinks == null) Uniforms.externalTextureLinks = [];
		Uniforms.externalFloatsLinks.push(floatsLink);
		Uniforms.externalIntLinks.push(intLink);
		Uniforms.externalFloatLinks.push(floatLink);
		Uniforms.externalMat4Links.push(mat4Link);
		Uniforms.externalTextureLinks.push(textureLink);
	}

	static function floatsLink(object: Object, mat: MaterialData, link: String): Float32Array {
		return link == "_eeveeLights" ? lights : null;
	}

	static function intLink(object: Object, mat: MaterialData, link: String): Null<Int> {
		return switch (link) {
			case "_eeveeLightCount": lightCount;
			case "_eeveeEnvMips": envMips;
			default: null;
		}
	}

	static function floatLink(object: Object, mat: MaterialData, link: String): Null<kha.FastFloat> {
		return link == "_eeveeEnvIntensity" ? envIntensity : null;
	}

	static function mat4Link(object: Object, mat: MaterialData, link: String): Mat4 {
		return link == "_eeveeEnvMatrix" ? envMatrix : null;
	}

	static function textureLink(object: Object, mat: MaterialData, link: String): kha.Image {
		return switch (link) {
			case "_eeveeEnvRadiance": envRadiance;
			case "_eeveeEnvIrradiance": envIrradiance;
			default: null;
		}
	}

	static function flatColor(value: Float): kha.Image {
		var bytes = haxe.io.Bytes.alloc(16);
		for (i in 0...3) bytes.setFloat(i * 4, value);
		bytes.setFloat(12, 1.0);
		return kha.Image.fromBytes(bytes, 1, 1, kha.graphics4.TextureFormat.RGBA128);
	}
}
