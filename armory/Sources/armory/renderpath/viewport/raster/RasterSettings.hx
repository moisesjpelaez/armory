package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportCompositor.TCompositor;

/**
	A scene's Eevee and render settings, named as in Blender. This is also the
	scene's settings file, as blender/arm/viewport/raster/settings.py write() makes it.
**/
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
	var shadow_pool_size: Int; // MB
	var shadow_step_count: Int;
	/** The AOVs of the scene's view layer, in its order. **/
	var aovs: Array<{name: String, type: String}>;
	/** The scene's compositor plan (blender/arm/viewport/compositor.py), or null without a compositor. **/
	var compositor: Null<TCompositor>;
}

/** An entry of the scene index (vpraster_scenes.json): the scene's colour table and settings files. **/
typedef TRasterSceneFiles = {
	var lut: String;
	var settings: String;
}

/**
	The active scene's Eevee and render settings (`current`). As in Blender, every
	scene has its own. The export (blender/arm/viewport) writes a settings file per
	scene and lists it in vpraster_scenes.json, with the scene's colour management
	table.
**/
class RasterSettings {

	/** The active scene's settings. Until the first scene's file has loaded, these are Blender's defaults. **/
	public static var current: TRasterSettings = {
		taa_samples: 16,
		filter_size: 1.5,
		clamp_surface_direct: 0.0,
		clamp_surface_indirect: 10.0,
		direct_light_intensity: 1.0,
		indirect_light_intensity: 1.0,
		light_threshold: 0.01,
		resolution_percentage: 100,
		film_transparent: false,
		dither_intensity: 1.0,
		use_shadows: true,
		shadow_pool_size: 512,
		shadow_step_count: 6,
		aovs: [],
		compositor: null
	};
	/** The names of `current.aovs`, in the same order (the compositor's aov0, aov1...). **/
	public static var aovNames: Array<String> = [];

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
				current = haxe.Json.parse(blob.toString());
				aovNames = [for (aov in current.aovs) aov.name];
				done(entry.lut);
			});
		});
	}
}
