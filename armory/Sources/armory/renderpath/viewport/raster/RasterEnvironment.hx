package armory.renderpath.viewport.raster;

import kha.arrays.Float32Array;
import iron.math.Mat4;

/**
	The world's lighting for the shaders: its baked radiance image, an irradiance
	image made from its spherical harmonics, and the matrix that turns a direction
	into the images' lookup space. The renderer calls update() every frame before
	drawing. RasterUniforms gives the values to the shaders.
**/
class RasterEnvironment {

	public static var radiance: kha.Image = null;
	public static var irradiance: kha.Image = null;
	public static var mips = 1;
	public static var intensity = 1.0;
	// Turns a Blender direction (x, y, z) into the latlong lookup's space (-y, z, -x).
	// The baked world image is an equirectangular render looking along +X with +Z up.
	// So +X is the image centre and -Y is to its right, as in Blender's Environment
	// Texture. The lookup (arm_latlong, Shaders/vpraster/vpraster_common.inc) is Y-up
	// with -Z at the centre. The world pass, the lighting pass and irradianceImage()
	// all use this mapping.
	public static var matrix = new Mat4(0, -1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 0, 0, 1);

	static var world: iron.data.WorldData = null;
	static var worldSet = false;
	static var black: kha.Image = null;

	/**
		Points the environment at the active world's baked probe when the world
		changes. Called every frame before drawing. A scene without a world has no
		world light, as in Blender: a black background and no ambient light.
	**/
	public static function update() {
		var w = iron.Scene.active.world;
		if (worldSet && w == world) return;
		worldSet = true;
		world = w;
		if (w == null) {
			if (black == null) black = blackImage();
			radiance = black;
			irradiance = black;
			mips = 1;
			intensity = 0.0;
			return;
		}
		if (w.probe == null || w.probe.radiance == null || w.probe.irradiance == null) {
			throw 'Viewport renderer: world "${w.name}" has no baked lighting';
		}
		radiance = w.probe.radiance;
		mips = w.probe.raw.radiance_mipmaps + 1;
		intensity = w.probe.raw.strength;
		irradiance = irradianceImage(w.probe.irradiance);
	}

	/**
		Makes a latlong irradiance image from the world's spherical harmonics, in the
		lighting pass's lookup layout (arm_latlong). Only the first order is used (see
		below). Each texel holds E / pi, so the lighting pass multiplies it by the
		diffuse colour directly. It is doubled because write_probes.sh_to_json halves
		the coefficients for the Forward and Deferred renderers.
	**/
	static function irradianceImage(sh: Float32Array): kha.Image {
		var width = 32, height = 16;
		var bytes = haxe.io.Bytes.alloc(width * height * 16);
		var c2 = 0.511664, c4 = 0.886227; // SH irradiance constants (Ramamoorthi and Hanrahan 2001)
		for (y in 0...height) for (x in 0...width) {
			// Inverse of the latlong lookup (Y-up), then back to Blender's Z-up
			var theta = ((x + 0.5) / width - 0.5) * 2 * Math.PI;
			var phi = (0.5 - (y + 0.5) / height) * Math.PI;
			var mx = Math.sin(theta) * Math.cos(phi), my = Math.sin(phi), mz = -Math.cos(theta) * Math.cos(phi);
			var nx = -mz, ny = -mx, nz = my;
			for (c in 0...3) {
				// Constant and linear bands only, matching Eevee: it lights diffuse
				// surfaces from the world with first-order harmonics.
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

	/** A 1 x 1 black image, for a scene without a world. **/
	static function blackImage(): kha.Image {
		var bytes = haxe.io.Bytes.alloc(16);
		bytes.setFloat(12, 1.0);
		return kha.Image.fromBytes(bytes, 1, 1, kha.graphics4.TextureFormat.RGBA128);
	}
}
