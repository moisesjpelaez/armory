package armory.renderpath.eevee;

/**
	The active scene's Eevee and render settings. Like Blender, every scene has
	its own: blender/arm/eevee exports them per scene, listed in eevee_scenes.json
	with the scene's colour management table. Defaults are Blender's.
**/
class EeveeSettings {

	public static var taaSamples = 16;
	public static var filterSize = 1.5;
	public static var clampSurfaceDirect = 0.0;
	public static var clampSurfaceIndirect = 10.0;
	public static var directLightIntensity = 1.0;
	public static var indirectLightIntensity = 1.0;
	public static var lightThreshold = 0.01;
	public static var resolutionPercentage = 100;
	public static var filmTransparent = false;
	public static var useShadows = true;
	public static var shadowPoolSize = 512; // MB

	/** Name of the scene the settings come from (null until a scene is applied). **/
	public static var sceneName: String = null;

	static var index: Dynamic = null;

	/** Loads eevee_scenes.json; synchronous on desktop. **/
	public static function loadIndex() {
		iron.data.Data.getBlob("eevee_scenes.json", function(blob: kha.Blob) {
			index = haxe.Json.parse(blob.toString());
		});
	}

	/**
		Applies the settings of `name` (an exported scene name) and returns its
		colour management table file, or null if the scene was not exported.
	**/
	public static function applyScene(name: String): String {
		sceneName = name;
		var entry: Dynamic = index != null ? Reflect.field(index, name) : null;
		if (entry == null) return null;
		iron.data.Data.getBlob(entry.settings, function(blob: kha.Blob) {
			var s: Dynamic = haxe.Json.parse(blob.toString());
			taaSamples = s.taa_samples;
			filterSize = s.filter_size;
			clampSurfaceDirect = s.clamp_surface_direct;
			clampSurfaceIndirect = s.clamp_surface_indirect;
			directLightIntensity = s.direct_light_intensity;
			indirectLightIntensity = s.indirect_light_intensity;
			lightThreshold = s.light_threshold;
			resolutionPercentage = s.resolution_percentage;
			filmTransparent = s.film_transparent;
			useShadows = s.use_shadows;
			shadowPoolSize = s.shadow_pool_size;
		});
		return entry.lut;
	}
}
