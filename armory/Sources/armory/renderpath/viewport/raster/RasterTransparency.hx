package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import iron.RenderPath;
import iron.Scene;
import iron.data.MaterialData;
import iron.object.MeshObject;

/**
	Draws the blended materials (Render Method: Blended) as Eevee draws them: after
	the opaque surfaces are lit and the AOVs written, each object lit in its own
	shader. The renderer calls draw(), then composite() when draw() drew anything.

	Without alpha (mx_graph.py decides, as Eevee does), a blended material is opaque.
	It hides and is hidden by other surfaces by depth. It is in the Transparent
	pass with full coverage, and it does not hide the AOVs of what is behind it.
	Eevee lights such materials in its forward pass. Here they write the material
	images after the AOVs (RenderPathViewportRaster.LATE_CONTEXT), so the lighting
	pass lights them with the rest, screen motion included. OPAQUE_CONTEXT then only
	copies their lit colour into TARGET with full coverage; it does not light them again.

	With alpha, a material is blended over what is behind it by its opacity.
	Objects are sorted back to front by their origin, not their geometry. They do
	not hide each other: only the depth of the opaque surfaces is tested.
	materials.py gives each material the passes for its settings, drawn in this order:
	- Transparency Overlap off: a depth pre-pass (DEPTH_CONTEXT) keeps only the
	  front-most surface, then CONTEXT draws it.
	- Transparency Overlap on, both sides drawn: the back faces (BACK_CONTEXT),
	  then the front faces over them (FRONT_CONTEXT).
	- Transparency Overlap on, Backface Culling on: CONTEXT alone.

	Both kinds are drawn into TARGET, cleared to transparent. It ends up with the
	premultiplied colour and the coverage, like Eevee's Transparent pass.
	composite() then puts it over the lit image, with the same result as drawing
	straight onto it.
**/
class RasterTransparency {

	// No pass name may start with another: Iron finds a material's pass by name prefix
	public static inline var CONTEXT = "vpraster_blend";
	public static inline var DEPTH_CONTEXT = "vpraster_front_depth";
	public static inline var BACK_CONTEXT = "vpraster_back_faces";
	public static inline var FRONT_CONTEXT = "vpraster_front_faces";
	public static inline var OPAQUE_CONTEXT = "vpraster_opaque";
	// The blended passes in drawing order, and their bits in a material's pass mask (see passesOf())
	static var PASSES = [DEPTH_CONTEXT, BACK_CONTEXT, FRONT_CONTEXT, CONTEXT];
	static var PASS_BITS = [1, 2, 4, 8];
	static inline var OPAQUE_BIT = 16;
	static inline var BLENDED_BITS = 4 | 8; // FRONT_CONTEXT or CONTEXT: the object needs sorting
	public static inline var TARGET = "vpraster_transparent";
	public static inline var COMPOSITE_PASS = "shader_datas/vpraster_blend_pass/vpraster_blend_pass";

	static var NO_BIND_PARAMS: Array<String> = [];
	// OPAQUE_CONTEXT reads the lit image through this sampler (materials.py OPAQUE_COVERAGE_SAMPLER)
	static var LIT_IMAGE: Array<String> = [RenderPathViewportRaster.HDR, "litImage"];
	static var objects: Array<MeshObject> = [];
	static var objectPasses: Array<Int> = []; // per object: its materials' pass mask
	static var depths: Array<Float> = []; // per object: the view-space z of its origin
	static var order: Array<Int> = []; // indices into objects, sorted back to front
	static var opaque: Array<MeshObject> = [];
	// Each material's pass mask, found once. A material's contexts never change, but
	// a mesh's materials can (a trait switching a slot), so the cache is per material.
	static var materialPasses = new Map<MaterialData, Int>();

	/** Draws the blended objects into TARGET. Returns whether there were any. **/
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
			// A mesh with both kinds of materials goes in both lists. Each pass draws only its own materials.
			if ((passes & OPAQUE_BIT) != 0) {
				opaque.push(mesh);
			}
			if ((passes & BLENDED_BITS) != 0) {
				// View-space z of the origin. More negative is farther.
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
			// Their lit colour with coverage 1. The lighting pass has already lit them.
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

	/** Called on a scene switch. Forgets the cached pass masks with the old scene's materials. **/
	public static function reset() {
		materialPasses.clear();
	}

	/** Puts TARGET over the lit image (vpraster_hdr): colour + lit * (1 - coverage). **/
	public static function composite(path: RenderPath) {
		ViewportTargets.setAlone(path, RenderPathViewportRaster.HDR);
		path.bindTarget(TARGET, "tex");
		path.drawShader(COMPOSITE_PASS);
	}

	/** Sorts back to front: the object whose origin is farther (more negative view z) comes first. **/
	static function fartherFirst(a: Int, b: Int): Int {
		return depths[a] < depths[b] ? -1 : depths[a] > depths[b] ? 1 : 0;
	}

	/** The combined pass mask of the mesh's materials (PASS_BITS and OPAQUE_BIT). **/
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
