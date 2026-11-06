package armory.renderpath.viewport.raster;

/**
	The active scene's Eevee and render settings. Like Blender, every scene has
	its own: blender/arm/viewport exports them per scene, listed in vpraster_scenes.json
	with the scene's colour management table. Defaults are Blender's.
**/
class RasterSettings {

	public static var taaSamples = 16;
	public static var filterSize = 1.5;
	public static var clampSurfaceDirect = 0.0;
	public static var clampSurfaceIndirect = 10.0;
	public static var directLightIntensity = 1.0;
	public static var indirectLightIntensity = 1.0;
	public static var lightThreshold = 0.01;
	public static var resolutionPercentage = 100;
	public static var filmTransparent = false;
	public static var ditherIntensity = 1.0;
	public static var useShadows = true;
	public static var shadowPoolSize = 512; // MB
	public static var shadowStepCount = 6;
	/** The AOVs of the scene's view layer: names, and "COLOR" or "VALUE". **/
	public static var aovNames: Array<String> = [];
	public static var aovTypes: Array<String> = [];
	/** The scene's compositor steps (blender/arm/viewport/compositor.py), null without one. **/
	public static var compositor: Dynamic = null;

	static inline var INDEX = "vpraster_scenes.json";
	static var index: Dynamic = null;

	/**
		Applies the settings of `name` (an exported scene name), then calls `done`
		with its colour management table file. Files load at once on Krom, but only
		after this returns in a browser: nothing may read the settings before `done`.
		Every exported scene is in the index (vpraster_scenes.json).
	**/
	public static function applyScene(name: String, done: String->Void) {
		iron.data.Data.getBlob(INDEX, function(indexBlob: kha.Blob) {
			if (index == null) index = haxe.Json.parse(indexBlob.toString());
			var entry: Dynamic = Reflect.field(index, name);
			if (entry == null) throw 'Viewport renderer: scene "$name" has no Eevee settings ($INDEX)';
			iron.data.Data.getBlob(entry.settings, function(blob: kha.Blob) {
				read(haxe.Json.parse(blob.toString()));
				done(entry.lut);
			});
		});
	}

	static function read(s: Dynamic) {
		taaSamples = s.taa_samples;
		filterSize = s.filter_size;
		clampSurfaceDirect = s.clamp_surface_direct;
		clampSurfaceIndirect = s.clamp_surface_indirect;
		directLightIntensity = s.direct_light_intensity;
		indirectLightIntensity = s.indirect_light_intensity;
		lightThreshold = s.light_threshold;
		resolutionPercentage = s.resolution_percentage;
		filmTransparent = s.film_transparent;
		ditherIntensity = s.dither_intensity;
		useShadows = s.use_shadows;
		shadowPoolSize = s.shadow_pool_size;
		shadowStepCount = s.shadow_step_count;
		var aovs: Array<Dynamic> = s.aovs;
		aovNames = [for (aov in aovs) aov.name];
		aovTypes = [for (aov in aovs) aov.type];
		compositor = s.compositor;
	}
}
