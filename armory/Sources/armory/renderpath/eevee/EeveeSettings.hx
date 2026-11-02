package armory.renderpath.eevee;

/**
	The played scene's Eevee and render settings, exported by
	blender/arm/eevee/settings.py. Defaults are Blender's.
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

	/** Loads eevee_settings.json; synchronous on desktop, so call it before creating targets. **/
	public static function load(done: Void->Void) {
		iron.data.Data.getBlob("eevee_settings.json", function(blob: kha.Blob) {
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
			done();
		});
	}
}
