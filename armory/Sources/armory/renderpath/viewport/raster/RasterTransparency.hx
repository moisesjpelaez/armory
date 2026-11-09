package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import iron.RenderPath;
import iron.Scene;
import iron.data.MaterialData;
import iron.object.MeshObject;

/**
	Blended materials (Render Method: Blended), drawn as Eevee draws them, as
	measured: after the opaque surfaces are lit and the AOVs written, each object
	lit in its own shader.

	Without alpha (mx_graph.py decides, as Eevee does) they are opaque: hidden by
	and hiding other surfaces by depth, in the Transparent pass with full
	coverage, and they don't hide the AOVs of what is behind them. Eevee lights
	them in its forward pass; here they write the material images after the AOVs
	(RenderPathViewportRaster.LATE_CONTEXT), so the lighting pass lights them with
	the rest, screen motion included, and OPAQUE_CONTEXT only copies their lit
	colour into TARGET with full coverage (no second lighting).

	With alpha, they are blended over what is behind them by their opacity,
	objects sorted back to front by their origin (not their geometry). They don't
	hide each other: only the depth of the opaque surfaces is tested. An object's
	passes, in order (materials.py gives each material its own): Transparency
	Overlap off, the depth pre-pass (DEPTH_CONTEXT) keeps only its front-most
	surface, then CONTEXT; on with both sides drawn, its back faces
	(BACK_CONTEXT), then its front faces over them (FRONT_CONTEXT); on with
	Backface Culling, CONTEXT alone.

	Both are drawn into TARGET, cleared to transparent, so it ends up with the
	colour (premultiplied) and coverage, like Eevee's Transparent pass.
	composite() then puts it over the lit image: the same result as drawing
	straight onto it.
**/
class RasterTransparency {

	// None is the start of another: Iron finds a material's pass by name prefix
	public static inline var CONTEXT = "vpraster_blend";
	public static inline var DEPTH_CONTEXT = "vpraster_front_depth";
	public static inline var BACK_CONTEXT = "vpraster_back_faces";
	public static inline var FRONT_CONTEXT = "vpraster_front_faces";
	public static inline var OPAQUE_CONTEXT = "vpraster_opaque";
	// Blended passes in drawing order, and their bits in a material's passes (passesOf())
	static var PASSES = [DEPTH_CONTEXT, BACK_CONTEXT, FRONT_CONTEXT, CONTEXT];
	static var PASS_BITS = [1, 2, 4, 8];
	static inline var OPAQUE_BIT = 16;
	static inline var BLENDED_BITS = 4 | 8; // FRONT_CONTEXT or CONTEXT: drawn blended
	public static inline var TARGET = "vpraster_transparent";
	public static inline var COMPOSITE_PASS = "shader_datas/vpraster_blend_pass/vpraster_blend_pass";

	static var NO_BIND_PARAMS: Array<String> = [];
	// OPAQUE_CONTEXT reads the lit image (materials.py OPAQUE_COVERAGE_SAMPLER)
	static var LIT_IMAGE: Array<String> = [RenderPathViewportRaster.HDR, "litImage"];
	static var objects: Array<MeshObject> = [];
	static var objectPasses: Array<Int> = []; // per object: its materials' passes (bits)
	static var depths: Array<Float> = [];
	static var order: Array<Int> = [];
	static var opaque: Array<MeshObject> = [];
	// A material's passes, found once: its contexts never change, while the
	// materials of a mesh can (a trait switching a slot)
	static var materialPasses = new Map<MaterialData, Int>();

	/** Draws the blended objects into TARGET; returns whether there were any. **/
	public static function draw(path: RenderPath): Bool {
		var camera = Scene.active.camera;
		var v = camera.V;
		objects.resize(0);
		objectPasses.resize(0);
		depths.resize(0);
		order.resize(0);
		opaque.resize(0);
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible) continue;
			var passes = passesOf(mesh);
			if (passes == 0) continue;
			// A mesh with both kinds of materials is in both lists (each pass draws its own)
			if ((passes & OPAQUE_BIT) != 0) {
				opaque.push(mesh);
			}
			if ((passes & BLENDED_BITS) != 0) {
				// View-space z of the origin: more negative is farther
				var t = mesh.transform;
				depths.push(v._02 * t.worldx() + v._12 * t.worldy() + v._22 * t.worldz() + v._32);
				order.push(objects.length);
				objects.push(mesh);
				objectPasses.push(passes);
			}
		}
		if (objects.length == 0 && opaque.length == 0) return false;

		ViewportTargets.setAlone(path, TARGET);
		path.clearTarget(0x00000000); // colour only: the depth buffer holds the opaque surfaces
		if (opaque.length > 0) {
			// Their lit colour, coverage 1: the lighting pass has lit them already
			var g = path.currentG;
			for (mesh in opaque) mesh.render(g, OPAQUE_CONTEXT, LIT_IMAGE);
		}
		if (objects.length > 0) {
			order.sort(fartherFirst);
			var g = path.currentG;
			for (i in order) {
				var mesh = objects[i];
				var passes = objectPasses[i];
				for (p in 0...PASSES.length) if ((passes & PASS_BITS[p]) != 0) mesh.render(g, PASSES[p], NO_BIND_PARAMS);
			}
		}
		return true;
	}

	/** A scene switch: the cached passes go with the old scene's materials. **/
	public static function reset() {
		materialPasses.clear();
	}

	/** Puts TARGET over the lit image (vpraster_hdr): colour + lit * (1 - coverage). **/
	public static function composite(path: RenderPath) {
		ViewportTargets.setAlone(path, RenderPathViewportRaster.HDR);
		path.bindTarget(TARGET, "tex");
		path.drawShader(COMPOSITE_PASS);
	}

	/** Back to front: the object whose origin is farther (more negative view z) first. **/
	static function fartherFirst(a: Int, b: Int): Int {
		return depths[a] < depths[b] ? -1 : depths[a] > depths[b] ? 1 : 0;
	}

	/** The passes (bits) of the mesh's materials. **/
	static function passesOf(mesh: MeshObject): Int {
		var passes = 0;
		for (mat in mesh.materials) {
			if (mat == null) continue;
			var bits = materialPasses.get(mat);
			if (bits == null) {
				bits = mat.getContext(OPAQUE_CONTEXT) != null ? OPAQUE_BIT : 0;
				for (p in 0...PASSES.length) if (mat.getContext(PASSES[p]) != null) bits |= PASS_BITS[p];
				materialPasses.set(mat, bits);
			}
			passes |= bits;
		}
		return passes;
	}
}
