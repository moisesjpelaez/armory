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
	public static inline var LIGHT_VEC4S = 6;

	public static var lights = new Float32Array(MAX_LIGHTS * LIGHT_VEC4S * 4);
	public static var lightCount = 0;

	public static var envRadiance: kha.Image = null;
	public static var envIrradiance: kha.Image = null;
	public static var envMips = 1;
	public static var envIntensity = 1.0;
	// Blender direction (x, y, z) -> MaterialX latlong space (-y, z, -x). The baked
	// world image is an equirectangular render looking along +X with +Z up, so
	// +X is the image centre and -Y is to its right (as Blender's Environment
	// Texture); MaterialX's lookup is Y-up with -Z at the centre.
	// Shaders/eevee_world_pass and irradianceImage() use the same mapping.
	static var envMatrix = new Mat4(0, -1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 0, 0, 1);

	// Colour management tables baked by blender/arm/eevee/color.py, one per distinct scene setup
	static inline var FILM_HEADER_FLOATS = 8;
	static var filmTables = new Map<String, kha.Image>();
	public static var filmLut: kha.Image = null;
	public static var filmLutSize = 0.0;
	public static var filmLutStops = new iron.math.Vec4(-12, 12);
	public static var filmExposure = 1.0;
	public static var filmInvGamma = 1.0;

	/** Eevee's measured specular tables (glsl_rewrite.EEVEE_SPECULAR), float RGBA: reflectance
		(32 x 32, x = A, y = B) and the lamp lobe (32 x 64, inverse LTC matrix, then its scale). **/
	static var dfg: kha.Image = null;
	static var ltc: kha.Image = null;

	public static function register() {
		iron.data.Data.getBlob("eevee_dfg.bin", function(blob: kha.Blob) {
			dfg = kha.Image.fromBytes(blob.toBytes(), 32, 32, kha.graphics4.TextureFormat.RGBA128);
		});
		iron.data.Data.getBlob("eevee_ltc.bin", function(blob: kha.Blob) {
			ltc = kha.Image.fromBytes(blob.toBytes(), 32, 64, kha.graphics4.TextureFormat.RGBA128);
		});
		if (envRadiance == null) {
			envRadiance = flatColor(0.5);
			envIrradiance = envRadiance;
		}
		filmLut = flatColor(0.0); // Placeholder until a table is loaded (filmLutSize 0 = plain sRGB)

		if (Uniforms.externalVec4Links == null) Uniforms.externalVec4Links = [];
		Uniforms.externalVec4Links.push(vec4Link);
		if (Uniforms.externalVec2Links == null) Uniforms.externalVec2Links = [];
		Uniforms.externalVec2Links.push(vec2Link);
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

	/** Switches to a colour management table (cached per file). **/
	public static function loadFilm(file: String) {
		iron.data.Data.getBlob(file, function(blob: kha.Blob) { readFilm(file, blob); });
	}

	static function readFilm(file: String, blob: kha.Blob) {
		var bytes = blob.toBytes();
		var size = Std.int(bytes.getFloat(4));
		filmLutStops.set(bytes.getFloat(8), bytes.getFloat(12), 0, 0);
		filmExposure = Math.pow(2.0, bytes.getFloat(16));
		filmInvGamma = 1.0 / bytes.getFloat(20);
		var cached = filmTables.get(file);
		if (cached == null) {
			var texels = bytes.sub(FILM_HEADER_FLOATS * 4, size * size * size * 8);
			cached = kha.Image.fromBytes(texels, size * size, size, kha.graphics4.TextureFormat.RGBA64);
			filmTables.set(file, cached);
		}
		filmLut = cached;
		filmLutSize = size;
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
		spherical harmonics, first order (see below). The result
		is E / pi (MaterialX multiplies the map by the diffuse albedo directly), times
		2 because write_probes.sh_to_json halves the coefficients for Forward/Deferred.
	**/
	static function irradianceImage(sh: Float32Array): kha.Image {
		var width = 32, height = 16;
		var bytes = haxe.io.Bytes.alloc(width * height * 16);
		var c2 = 0.511664, c4 = 0.886227;
		for (y in 0...height) for (x in 0...width) {
			// Inverse of MaterialX's latlong projection (Y-up), then back to Blender's Z-up
			var theta = ((x + 0.5) / width - 0.5) * 2 * Math.PI;
			var phi = (0.5 - (y + 0.5) / height) * Math.PI;
			var mx = Math.sin(theta) * Math.cos(phi), my = Math.sin(phi), mz = -Math.cos(theta) * Math.cos(phi);
			var nx = -mz, ny = -mx, nz = my;
			for (c in 0...3) {
				// Constant and linear bands only: Eevee lights diffuse surfaces from the
				// world with first-order harmonics (measured: an up-facing floor under
				// larimar's sky matches order 1 within 0.001, order 2 is bluer).
				var value =
					c4 * sh[c] +
					2 * c2 * sh[9 + c] * ny +
					2 * c2 * sh[3 + c] * (-nz) +
					2 * c2 * sh[6 + c] * nx;
				bytes.setFloat((y * width + x) * 16 + c * 4, Math.max(value, 0.0) * 2.0 / Math.PI);
			}
			bytes.setFloat((y * width + x) * 16 + 12, 1.0);
		}
		return kha.Image.fromBytes(bytes, width, height, kha.graphics4.TextureFormat.RGBA128);
	}

	static function floatsLink(object: Object, mat: MaterialData, link: String): Float32Array {
		return switch (link) {
			case "_eeveeLights": lights;
			case "_eeveeShadows": EeveeShadows.views;
			default: null;
		}
	}

	static function intLink(object: Object, mat: MaterialData, link: String): Null<Int> {
		return switch (link) {
			case "_eeveeLightCount": lightCount;
			case "_eeveeEnvMips": envMips;
			default: null;
		}
	}

	static function floatLink(object: Object, mat: MaterialData, link: String): Null<kha.FastFloat> {
		return switch (link) {
			case "_eeveeEnvIntensity": envIntensity;
			case "_eeveeFilmLutSize": filmLutSize;
			case "_eeveeFilmExposure": filmExposure;
			case "_eeveeFilmInvGamma": filmInvGamma;
			default: null;
		}
	}

	static var direct = new iron.math.Vec4();
	static var dither = new iron.math.Vec4();
	static var ditherFrame = 0;
	static var indirect = new iron.math.Vec4();

	static function vec2Link(object: Object, mat: MaterialData, link: String): iron.math.Vec4 {
		return switch (link) {
			case "_eeveeFilmLutStops": filmLutStops;
			case "_eeveeDirect": direct.set(EeveeSettings.directLightIntensity, EeveeSettings.clampSurfaceDirect, 0, 0);
			case "_eeveeIndirect": indirect.set(EeveeSettings.indirectLightIntensity, EeveeSettings.clampSurfaceIndirect, 0, 0);
			case "_eeveeDither": dither.set(EeveeSettings.ditherIntensity, ditherFrame = (ditherFrame + 1) % 64, 0, 0);
			default: null;
		}
	}

	static function mat4Link(object: Object, mat: MaterialData, link: String): Mat4 {
		return switch (link) {
			case "_eeveeEnvMatrix": envMatrix;
			case "_eeveeVP": EeveeTaa.vp;
			case "_eeveePrevVP": EeveeTaa.prevVP;
			case "_eeveeShadowVP": EeveeShadows.viewProjection;
			default: null;
		}
	}

	static var viewDir = new iron.math.Vec4();

	static function vec4Link(object: Object, mat: MaterialData, link: String): iron.math.Vec4 {
		return switch (link) {
			case "_eeveeTaa": EeveeTaa.params;
			case "_eeveeViewDir": viewDirection();
			case "_eeveeShadowInfo": EeveeShadows.info;
			case "_eeveeShadowDepth": EeveeShadows.depthRow;
			default: null;
		}
	}

	/** xyz: towards the camera, w: 1 for an orthographic camera (all view rays parallel). **/
	static function viewDirection(): iron.math.Vec4 {
		var camera = iron.Scene.active.camera;
		if (camera.P._23 != 0) return viewDir.set(0, 0, 0, 0); // Perspective
		var look = camera.lookWorld().normalize();
		return viewDir.set(-look.x, -look.y, -look.z, 1);
	}

	static function textureLink(object: Object, mat: MaterialData, link: String): kha.Image {
		return switch (link) {
			case "_eeveeEnvRadiance": envRadiance;
			case "_eeveeEnvIrradiance": envIrradiance;
			case "_eeveeFilmLut": filmLut;
			case "_eeveeDfg": dfg;
			case "_eeveeLtc": ltc;
			case "_eeveeShadowMap": EeveeShadows.atlas != null ? EeveeShadows.atlas : flatColor(1.0);
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
