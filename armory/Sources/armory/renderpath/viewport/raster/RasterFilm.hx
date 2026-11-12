package armory.renderpath.viewport.raster;

/**
	The film's colour management table: a 3D lookup table that the film pass uses
	to map the scene-linear image to the screen as Blender does.
	blender/arm/viewport/color.py bakes one file per distinct scene setup. Each
	file starts with a header of HEADER_FLOATS floats (see read()).

	The renderer calls load() on a scene switch, and draws only once ready() is
	true. RasterUniforms gives `lut`, `lutSize` and `lutStops` to the film pass.
**/
class RasterFilm {

	static inline var HEADER_FLOATS = 4;

	/** The table in use: `lutSize` slices of lutSize x lutSize texels, side by side. **/
	public static var lut: kha.Image = null;
	public static var lutSize = 0.0;
	/** The shaper's lowest (x) and highest (y) stop. **/
	public static var lutStops = new iron.math.Vec4(-12, 12);

	static var tables = new Map<String, kha.Image>(); // every table loaded so far, by file
	/** The table asked for last, and the one in use (`lut`). **/
	static var file: String = null;
	static var loaded: String = null;

	/** Switches to a colour management table, cached per file. ready() tells when it has loaded. **/
	public static function load(name: String) {
		file = name;
		iron.data.Data.getBlob(name, function(blob: kha.Blob) { read(name, blob); });
	}

	/** Whether the table asked for last has loaded (at once on Krom, later in a browser). **/
	public static function ready(): Bool {
		return loaded != null && loaded == file;
	}

	static function read(name: String, blob: kha.Blob) {
		if (name != file) return; // another scene's table was asked for meanwhile
		// Header: table size, the shaper's lowest and highest stop, 0
		var bytes = blob.toBytes();
		var size = Std.int(bytes.getFloat(0));
		lutStops.set(bytes.getFloat(4), bytes.getFloat(8), 0, 0);
		var cached = tables.get(name);
		if (cached == null) {
			// The table is stored as 32-bit floats (blender/arm/viewport/color.py), laid
			// out as `size` slices of size x size side by side.
			// KHA-HTML5: Kha's HTML5 backend hands half floats made from bytes to WebGL
			// as a Float32Array, which WebGL refuses (WebGLImage.bytesToArray). 32-bit
			// floats avoid this. Filtering them needs no WebGL extension the specular
			// tables do not already need. Half floats can be used once Kha converts them.
			var texels = RasterUniforms.fileBytes(blob, HEADER_FLOATS * 4, size * size * size * 16);
			cached = kha.Image.fromBytes(texels, size * size, size, kha.graphics4.TextureFormat.RGBA128);
			tables.set(name, cached);
		}
		lut = cached;
		lutSize = size;
		loaded = name;
	}
}
