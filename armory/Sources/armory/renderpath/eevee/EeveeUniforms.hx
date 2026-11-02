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

	static var world: iron.data.WorldData = null;

	/** Points the environment at the active world's baked probe when the world changes. **/
	public static function updateWorld() {
		var w = iron.Scene.active.world;
		if (w == world || w == null || w.probe == null || w.probe.radiance == null || w.probe.irradiance == null) return;
		world = w;
		envRadiance = w.probe.radiance;
		envMips = w.probe.raw.radiance_mipmaps + 1;
		envIntensity = w.probe.raw.strength;
		envIrradiance = irradianceImage(w.probe.irradiance);
	}

	/**
		Latlong irradiance image in the layout MaterialX samples, from the world's
		spherical harmonics (same evaluation as Shaders/std/shirr.glsl, divided by
		pi: MaterialX multiplies the map by the diffuse albedo directly).
	**/
	static function irradianceImage(sh: Float32Array): kha.Image {
		var width = 32, height = 16;
		var bytes = haxe.io.Bytes.alloc(width * height * 16);
		var c1 = 0.429043, c2 = 0.511664, c3 = 0.743125, c4 = 0.886227, c5 = 0.247708;
		for (y in 0...height) for (x in 0...width) {
			// Inverse of MaterialX's latlong projection (Y-up), then back to Blender's Z-up
			var theta = ((x + 0.5) / width - 0.5) * 2 * Math.PI;
			var phi = (0.5 - (y + 0.5) / height) * Math.PI;
			var mx = Math.sin(theta) * Math.cos(phi), my = Math.sin(phi), mz = -Math.cos(theta) * Math.cos(phi);
			var nx = mx, ny = -mz, nz = my;
			for (c in 0...3) {
				var value =
					c1 * sh[24 + c] * (ny * ny - nz * nz) +
					c3 * sh[18 + c] * nx * nx +
					c4 * sh[c] -
					c5 * sh[18 + c] +
					2 * c1 * sh[12 + c] * ny * (-nz) +
					2 * c1 * sh[21 + c] * ny * nx +
					2 * c1 * sh[15 + c] * (-nz) * nx +
					2 * c2 * sh[9 + c] * ny +
					2 * c2 * sh[3 + c] * (-nz) +
					2 * c2 * sh[6 + c] * nx;
				bytes.setFloat((y * width + x) * 16 + c * 4, Math.max(value, 0.0) / Math.PI);
			}
			bytes.setFloat((y * width + x) * 16 + 12, 1.0);
		}
		return kha.Image.fromBytes(bytes, width, height, kha.graphics4.TextureFormat.RGBA128);
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
