package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportCompositor;
import kha.arrays.Float32Array;
import iron.data.MaterialData;
import iron.math.Mat4;
import iron.object.Object;
import iron.object.Uniforms;

/**
	Values the Viewport renderer's shaders read from the engine (material, lighting,
	world, TAA and film passes), registered through Iron's external uniform links.
**/
class RasterUniforms {

	// Read by the build (blender/arm/viewport/engine.py) for the shaders
	public static inline var MAX_LIGHTS = 8;
	public static inline var LIGHT_VEC4S = 6;

	public static var lights = new Float32Array(MAX_LIGHTS * LIGHT_VEC4S * 4);
	public static var lightCount = 0;

	public static var envRadiance: kha.Image = null;
	public static var envIrradiance: kha.Image = null;
	public static var envMips = 1;
	public static var envIntensity = 1.0;
	// Blender direction (x, y, z) -> latlong lookup space (-y, z, -x). The baked
	// world image is an equirectangular render looking along +X with +Z up, so
	// +X is the image centre and -Y is to its right (as Blender's Environment
	// Texture); the lookup (arm_latlong, Shaders/vpraster/vpraster_common.inc) is Y-up
	// with -Z at the centre. The world pass, the lighting pass and
	// irradianceImage() use this same mapping.
	static var envMatrix = new Mat4(0, -1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 0, 0, 1);

	// Colour management tables baked by blender/arm/viewport/color.py, one per distinct scene setup
	static inline var FILM_HEADER_FLOATS = 8;
	static var filmTables = new Map<String, kha.Image>();
	public static var filmLut: kha.Image = null;
	public static var filmLutSize = 0.0;
	public static var filmLutStops = new iron.math.Vec4(-12, 12);
	public static var filmExposure = 1.0;
	public static var filmInvGamma = 1.0;

	/** Eevee's measured specular tables (Shaders/vpraster/vpraster_specular.glsl), float RGBA: reflectance
		(32 x 32, x = A, y = B) and the lamp lobe (32 x 64, inverse LTC matrix, then its scale). **/
	static var dfg: kha.Image = null;
	static var ltc: kha.Image = null;

	public static function register() {
		iron.data.Data.getBlob("vpraster_dfg.bin", function(blob: kha.Blob) {
			dfg = kha.Image.fromBytes(blob.toBytes(), 32, 32, kha.graphics4.TextureFormat.RGBA128);
		});
		iron.data.Data.getBlob("vpraster_ltc.bin", function(blob: kha.Blob) {
			ltc = kha.Image.fromBytes(blob.toBytes(), 32, 64, kha.graphics4.TextureFormat.RGBA128);
		});
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
	static var worldSet = false;
	static var black: kha.Image = null;

	/**
		Points the environment at the active world's baked probe when the world
		changes. A scene without a world has no world light, as in Blender (measured:
		black background, no ambient light).
	**/
	public static function updateWorld() {
		var w = iron.Scene.active.world;
		if (worldSet && w == world) return;
		worldSet = true;
		world = w;
		if (w == null) {
			if (black == null) black = blackImage();
			envRadiance = black;
			envIrradiance = black;
			envMips = 1;
			envIntensity = 0.0;
			return;
		}
		if (w.probe == null || w.probe.radiance == null || w.probe.irradiance == null) {
			throw 'Viewport renderer: world "${w.name}" has no baked lighting';
		}
		envRadiance = w.probe.radiance;
		envMips = w.probe.raw.radiance_mipmaps + 1;
		envIntensity = w.probe.raw.strength;
		envIrradiance = irradianceImage(w.probe.irradiance);
	}

	/**
		Latlong irradiance image in the lighting pass's lookup layout (arm_latlong),
		from the world's spherical harmonics, first order (see below). The result
		is E / pi (the lighting pass multiplies it by the diffuse colour directly), times
		2 because write_probes.sh_to_json halves the coefficients for Forward/Deferred.
	**/
	static function irradianceImage(sh: Float32Array): kha.Image {
		var width = 32, height = 16;
		var bytes = haxe.io.Bytes.alloc(width * height * 16);
		var c2 = 0.511664, c4 = 0.886227;
		for (y in 0...height) for (x in 0...width) {
			// Inverse of the latlong lookup (Y-up), then back to Blender's Z-up
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
			case "_vprasterLights": lights;
			case "_vprasterShadows": RasterShadows.views;
			#if arm_skin
			case "_vprasterSkinMatrices": { var anim = skin(object); anim != null ? anim.skinMatrices : null; }
			case "_vprasterSkinMatricesPrev": previous(skin(object), true);
			case "_vprasterSkinBonesPrev": previous(skin(object), false);
			#end
			default: null;
		}
	}

	#if arm_skin
	// Last frame's skin of each skinned object (motion vectors), copied after
	// each frame is drawn, so a paused or skipped animation has no motion
	static var prevMatrices = new Map<iron.object.BoneAnimation, Float32Array>();
	static var prevBones = new Map<iron.object.BoneAnimation, Float32Array>();
	static var animationCount = -1;
	static var animationScene: iron.Scene = null;

	static inline function skin(object: Object): iron.object.BoneAnimation {
		return object != null ? Std.downcast(object.animation, iron.object.BoneAnimation) : null;
	}

	static function previous(anim: iron.object.BoneAnimation, matrices: Bool): Float32Array {
		if (anim == null) return null;
		var prev = (matrices ? prevMatrices : prevBones).get(anim);
		return prev != null ? prev : (matrices ? anim.skinMatrices : anim.skinBuffer);
	}

	/** Call after drawing the frame: remembers every skin for the next frame's motion vectors. **/
	public static function endFrame() {
		if (iron.Scene.active == null) return;
		var animations = iron.Scene.active.animations;
		for (a in animations) {
			var anim = Std.downcast(a, iron.object.BoneAnimation);
			if (anim == null || anim.skinBuffer == null) continue;
			copy(prevMatrices, anim, anim.skinMatrices);
			copy(prevBones, anim, anim.skinBuffer);
		}
		// Forget animations that left the scene: checked when their number or the scene
		// changes (a swap within the same frame waits for the next such change)
		if (animations.length != animationCount || iron.Scene.active != animationScene) {
			animationCount = animations.length;
			animationScene = iron.Scene.active;
			for (anim in [for (k in prevBones.keys()) k]) {
				if (animations.indexOf(anim) < 0) {
					prevBones.remove(anim);
					prevMatrices.remove(anim);
				}
			}
		}
	}

	static function copy(into: Map<iron.object.BoneAnimation, Float32Array>, anim: iron.object.BoneAnimation, from: Float32Array) {
		var to = into.get(anim);
		if (to == null) into.set(anim, to = new Float32Array(from.length));
		for (i in 0...from.length) to[i] = from[i];
	}
	#end

	static function intLink(object: Object, mat: MaterialData, link: String): Null<Int> {
		return switch (link) {
			case "_vprasterLightCount": lightCount;
			case "_vprasterEnvMips": envMips;
			default: null;
		}
	}

	static function floatLink(object: Object, mat: MaterialData, link: String): Null<kha.FastFloat> {
		return switch (link) {
			case "_vprasterEnvIntensity": envIntensity;
			case "_vprasterFilmLutSize": filmLutSize;
			case "_vprasterFilmExposure": filmExposure;
			case "_vprasterFilmInvGamma": filmInvGamma;
			case "_vprasterFrame": RasterTaa.frame % 1024;
			default: null;
		}
	}

	static var direct = new iron.math.Vec4();
	static var dither = new iron.math.Vec4();
	static var indirect = new iron.math.Vec4();

	static function vec2Link(object: Object, mat: MaterialData, link: String): iron.math.Vec4 {
		return switch (link) {
			case "_vprasterFilmLutStops": filmLutStops;
			case "_vprasterDirect": direct.set(RasterSettings.directLightIntensity, RasterSettings.clampSurfaceDirect, 0, 0);
			case "_vprasterIndirect": indirect.set(RasterSettings.indirectLightIntensity, RasterSettings.clampSurfaceIndirect, 0, 0);
			case "_vprasterDither": dither.set(RasterSettings.ditherIntensity, RasterTaa.frame % 64, 0, 0);
			default: null;
		}
	}

	static function mat4Link(object: Object, mat: MaterialData, link: String): Mat4 {
		return switch (link) {
			case "_vprasterEnvMatrix": envMatrix;
			case "_vprasterVP": RasterTaa.vp;
			case "_vprasterPrevVP": RasterTaa.prevVP;
			case "_vprasterShadowVP": RasterShadows.viewProjection;
			default: null;
		}
	}

	static var viewDir = new iron.math.Vec4();

	static function vec4Link(object: Object, mat: MaterialData, link: String): iron.math.Vec4 {
		return switch (link) {
			case "_vprasterTaa": RasterTaa.params;
			case "_viewportGlare0": ViewportCompositor.glare0;
			case "_viewportGlare1": ViewportCompositor.glare1;
			case "_viewportGlare2": ViewportCompositor.glare2;
			case "_viewportGlare3": ViewportCompositor.glare3;
			case "_viewportGlareTint": ViewportCompositor.glareTint;
			case "_vprasterViewDir": viewDirection();
			case "_vprasterShadowInfo": RasterShadows.info;
			case "_vprasterShadowDepth": RasterShadows.depthRow;
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
			case "_vprasterEnvRadiance": envRadiance;
			case "_vprasterEnvIrradiance": envIrradiance;
			case "_vprasterFilmLut": filmLut;
			case "_vprasterDfg": dfg;
			case "_vprasterLtc": ltc;
			case "_vprasterShadowMap": RasterShadows.atlas; // created at the start of every frame (RasterShadows.render)
			default: null;
		}
	}

	static function blackImage(): kha.Image {
		var bytes = haxe.io.Bytes.alloc(16);
		bytes.setFloat(12, 1.0);
		return kha.Image.fromBytes(bytes, 1, 1, kha.graphics4.TextureFormat.RGBA128);
	}
}
