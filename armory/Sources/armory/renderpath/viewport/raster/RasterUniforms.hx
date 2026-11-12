package armory.renderpath.viewport.raster;

import kha.arrays.Float32Array;
import iron.data.MaterialData;
import iron.math.Mat4;
import iron.object.Object;
import iron.object.Uniforms;

/**
	Values the Viewport renderer's shaders read from the engine. Iron passes them
	to the shaders through its external uniform links, registered in register().
	Each link function below answers the links of one uniform type.

	The values themselves live with the code that makes them:
	- lights: `lights` here, filled by RasterLights
	- shadows: RasterShadows
	- world lighting: RasterEnvironment
	- TAA: RasterTaa
	- motion vectors: RasterMotionHistory
	- the film's colour table: RasterFilm
	- Eevee's specular tables and the view direction: here

	The renderer calls beginFrame() before drawing a frame.
**/
class RasterUniforms {

	// The build reads these two for the shaders (blender/arm/viewport/raster/engine.py).
	// It finds them by name in this file, so they stay here, each a `static inline var`.
	public static inline var MAX_LIGHTS = 8;
	public static inline var LIGHT_VEC4S = 6;

	public static var lights = new Float32Array(MAX_LIGHTS * LIGHT_VEC4S * 4); // filled by RasterLights
	public static var lightCount = 0;

	/**
		Eevee's specular tables, as float RGBA images (see Shaders/vpraster/vpraster_specular.glsl).
		- dfg: the reflectance, 32 x 32 (x = A, y = B).
		- ltc: the lamp lobe for linearly transformed cosines (LTC, Heitz et al. 2016),
		  32 x 64: the inverse LTC matrix, then its scale.
	**/
	static var dfg: kha.Image = null;
	static var ltc: kha.Image = null;

	// Reused by the links below, so they allocate nothing
	static var direct = new iron.math.Vec4();
	static var dither = new iron.math.Vec4();
	static var indirect = new iron.math.Vec4();
	static var viewDir = new iron.math.Vec4();

	/** Loads the specular tables and registers the link functions with Iron. Called once, from the renderer's init(). **/
	public static function register() {
		iron.data.Data.getBlob("vpraster_dfg.bin", function(blob: kha.Blob) {
			dfg = kha.Image.fromBytes(fileBytes(blob), 32, 32, kha.graphics4.TextureFormat.RGBA128);
		});
		iron.data.Data.getBlob("vpraster_ltc.bin", function(blob: kha.Blob) {
			ltc = kha.Image.fromBytes(fileBytes(blob), 32, 64, kha.graphics4.TextureFormat.RGBA128);
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

	/**
		Returns a copy of a loaded file's bytes, from `start` (`length` -1: to the end).

		KHA-HTML5: Kha's HTML5 loader (LoaderImpl.loadRemote) gives Bytes.ofData() a
		Uint8Array instead of its ArrayBuffer. An image made from those bytes
		(Image.fromBytes) then gets one float per byte. A copy has a buffer of its
		own. Krom needs no copy. This can go once Kha passes the ArrayBuffer.
	**/
	public static inline function fileBytes(blob: kha.Blob, start = 0, length = -1): haxe.io.Bytes {
		var bytes = blob.toBytes();
		return bytes.sub(start, length < 0 ? bytes.length - start : length);
	}

	/** Whether the specular tables have loaded (at once on Krom, later in a browser). **/
	public static function tablesReady(): Bool {
		return dfg != null && ltc != null;
	}

	/**
		Sets the values that change once per frame, before drawing: the view
		direction. For an orthographic camera (all view rays parallel), xyz points
		towards the camera and w is 1. A perspective camera gets all zeros.
	**/
	public static function beginFrame() {
		var camera = iron.Scene.active.camera;
		if (camera.P._23 != 0) {
			viewDir.set(0, 0, 0, 0);
			return;
		}
		var look = camera.lookWorld().normalize();
		viewDir.set(-look.x, -look.y, -look.z, 1);
	}

	static function floatsLink(object: Object, mat: MaterialData, link: String): Float32Array {
		return switch (link) {
			case "_vprasterLights": lights;
			case "_vprasterShadows": RasterShadows.views;
			case "_vprasterTaaWeights": RasterTaa.weights;
			#if arm_skin
			case "_vprasterSkinMatrices": { var anim = RasterMotionHistory.skin(object); anim != null ? anim.skinMatrices : null; }
			case "_vprasterSkinMatricesPrev": RasterMotionHistory.previousSkin(RasterMotionHistory.skin(object), true);
			case "_vprasterSkinBonesPrev": RasterMotionHistory.previousSkin(RasterMotionHistory.skin(object), false);
			#end
			default: null;
		}
	}

	static function intLink(object: Object, mat: MaterialData, link: String): Null<Int> {
		return switch (link) {
			case "_vprasterLightCount": lightCount;
			case "_vprasterEnvMips": RasterEnvironment.mips;
			default: null;
		}
	}

	static function floatLink(object: Object, mat: MaterialData, link: String): Null<kha.FastFloat> {
		return switch (link) {
			case "_vprasterEnvIntensity": RasterEnvironment.intensity;
			case "_vprasterFilmLutSize": RasterFilm.lutSize;
			case "_vprasterFrame": RasterTaa.longNoiseFrame();
			default: null;
		}
	}

	static function vec2Link(object: Object, mat: MaterialData, link: String): iron.math.Vec4 {
		var settings = RasterSettings.current;
		return switch (link) {
			case "_vprasterFilmLutStops": RasterFilm.lutStops;
			case "_vprasterDirect": direct.set(settings.direct_light_intensity, settings.clamp_surface_direct, 0, 0);
			case "_vprasterIndirect": indirect.set(settings.indirect_light_intensity, settings.clamp_surface_indirect, 0, 0);
			case "_vprasterDither": dither.set(settings.dither_intensity, RasterTaa.noiseFrame(), 0, 0);
			default: null;
		}
	}

	static function mat4Link(object: Object, mat: MaterialData, link: String): Mat4 {
		return switch (link) {
			case "_vprasterEnvMatrix": RasterEnvironment.matrix;
			case "_vprasterVP": RasterTaa.vp;
			case "_vprasterPrevVP": RasterTaa.prevVP;
			case "_vprasterPrevWorld": RasterMotionHistory.previousWorld(object);
			case "_vprasterShadowVP": RasterShadows.viewProjection;
			default: null;
		}
	}

	static function vec4Link(object: Object, mat: MaterialData, link: String): iron.math.Vec4 {
		return switch (link) {
			case "_vprasterTaa": RasterTaa.params;
			case "_vprasterViewDir": viewDir;
			case "_vprasterShadowInfo": RasterShadows.info;
			case "_vprasterShadowDepth": RasterShadows.depthRow;
			default: null;
		}
	}

	static function textureLink(object: Object, mat: MaterialData, link: String): kha.Image {
		return switch (link) {
			case "_vprasterEnvRadiance": RasterEnvironment.radiance;
			case "_vprasterEnvIrradiance": RasterEnvironment.irradiance;
			case "_vprasterFilmLut": RasterFilm.lut;
			case "_vprasterDfg": dfg;
			case "_vprasterLtc": ltc;
			case "_vprasterShadowMap_depth": RasterShadows.atlas; // Iron binds the depth buffer for links ending in _depth. RasterShadows.render() remakes the atlas when its size changes.
			default: null;
		}
	}
}
