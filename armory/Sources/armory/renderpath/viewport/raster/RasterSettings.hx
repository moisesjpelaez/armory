package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportCompositor.TCompositor;

/** A scene's settings file, as blender/arm/viewport/raster/settings.py write() makes it. **/
typedef TRasterSettings = {
	var taa_samples: Int;
	var filter_size: Float;
	var clamp_surface_direct: Float;
	var clamp_surface_indirect: Float;
	var direct_light_intensity: Float;
	var indirect_light_intensity: Float;
	var light_threshold: Float;
	var resolution_percentage: Int;
	var film_transparent: Bool;
	var dither_intensity: Float;
	var use_shadows: Bool;
	var shadow_pool_size: Int;
	var shadow_step_count: Int;
	var aovs: Array<{name: String, type: String}>;
	var compositor: Null<TCompositor>;
}

/** An entry of the scene index (vpraster_scenes.json): the scene's colour table and settings files. **/
typedef TRasterSceneFiles = {
	var lut: String;
	var settings: String;
}

/**
	The active scene's Eevee and render settings. As in Blender, every scene has
	its own. The export (blender/arm/viewport) writes a settings file per scene and
	lists it in vpraster_scenes.json, with the scene's colour management table.
	The defaults are Blender's.
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
	/** The AOVs of the scene's view layer, in its order (the compositor's aov0, aov1...). **/
	public static var aovNames: Array<String> = [];
	/** The scene's compositor plan (blender/arm/viewport/compositor.py), or null without a compositor. **/
	public static var compositor: TCompositor = null;

	static inline var INDEX = "vpraster_scenes.json";
	static var index: haxe.DynamicAccess<TRasterSceneFiles> = null;

	/**
		Applies the settings of the exported scene `name`, then calls `done` with its
		colour management table file. Krom loads files at once, but a browser loads
		them only after this returns. So nothing may read the settings before `done`.
		Every exported scene is in the index (vpraster_scenes.json).
	**/
	public static function applyScene(name: String, done: String->Void) {
		iron.data.Data.getBlob(INDEX, function(indexBlob: kha.Blob) {
			if (index == null) index = haxe.Json.parse(indexBlob.toString());
			var entry = index.get(name);
			if (entry == null) throw 'Viewport renderer: scene "$name" has no Eevee settings ($INDEX)';
			iron.data.Data.getBlob(entry.settings, function(blob: kha.Blob) {
				read(haxe.Json.parse(blob.toString()));
				done(entry.lut);
			});
		});
	}

	static function read(s: TRasterSettings) {
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
		aovNames = [for (aov in s.aovs) aov.name];
		compositor = s.compositor;
	}
}
