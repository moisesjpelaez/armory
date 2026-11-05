package armory.renderpath.eevee;

import iron.RenderPath;
import iron.Scene;
import iron.object.MeshObject;

/**
	Blended materials (Render Method: Blended) with alpha, drawn as Eevee draws
	them, as measured (without alpha they are opaque, in the G-buffer, as in
	Eevee; mx_graph.py decides): after the opaque surfaces are lit, each object lit in its own
	shader and blended over what is behind it by its opacity, objects sorted back
	to front by their origin (not their geometry). Blended objects don't hide each
	other: only the opaque surfaces' depth is tested.

	They are drawn into TARGET, cleared to transparent, so it ends up with the
	blended colour (premultiplied) and coverage, like Eevee's Transparent pass.
	composite() then puts it over the lit image: the same result as blending
	straight onto it.

	An object's passes, in order (materials.py gives each material its own):
	Transparency Overlap off, the depth pre-pass (DEPTH_CONTEXT) keeps only its
	front-most surface, then CONTEXT; on with both sides drawn, its back faces
	(BACK_CONTEXT), then its front faces over them (FRONT_CONTEXT); on with
	Backface Culling, CONTEXT alone.
**/
class EeveeTransparency {

	// None is the start of another: Iron finds a material's pass by name prefix
	public static inline var CONTEXT = "eevee_blend";
	public static inline var DEPTH_CONTEXT = "eevee_front_depth";
	public static inline var BACK_CONTEXT = "eevee_back_faces";
	public static inline var FRONT_CONTEXT = "eevee_front_faces";
	static var PASSES = [DEPTH_CONTEXT, BACK_CONTEXT, FRONT_CONTEXT, CONTEXT];
	public static inline var TARGET = "eevee_transparent";
	public static inline var COMPOSITE_PASS = "shader_datas/eevee_blend_pass/eevee_blend_pass";

	static var NO_BIND_PARAMS: Array<String> = [];
	static var objects: Array<MeshObject> = [];
	static var depths: Array<Float> = [];
	static var order: Array<Int> = [];

	/** Draws the blended objects into TARGET; returns whether there were any. **/
	public static function draw(path: RenderPath): Bool {
		var camera = Scene.active.camera;
		var v = camera.V;
		objects.resize(0);
		depths.resize(0);
		order.resize(0);
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible || !isBlended(mesh)) continue;
			var t = mesh.transform;
			// View-space z of the origin: more negative is farther
			depths.push(v._02 * t.worldx() + v._12 * t.worldy() + v._22 * t.worldz() + v._32);
			order.push(objects.length);
			objects.push(mesh);
		}
		if (objects.length == 0) return false;
		order.sort(function(a, b) return depths[a] < depths[b] ? -1 : depths[a] > depths[b] ? 1 : 0);

		path.setTarget(TARGET);
		path.clearTarget(0x00000000); // colour only: the depth buffer holds the opaque surfaces
		var g = path.currentG;
		for (i in order) {
			var mesh = objects[i];
			for (pass in PASSES) if (hasContext(mesh, pass)) mesh.render(g, pass, NO_BIND_PARAMS);
		}
		return true;
	}

	static function isBlended(mesh: MeshObject): Bool {
		return hasContext(mesh, CONTEXT) || hasContext(mesh, FRONT_CONTEXT);
	}

	/** Puts TARGET over the lit image (eevee_hdr): colour + lit * (1 - coverage). **/
	public static function composite(path: RenderPath) {
		path.setTarget("eevee_hdr");
		path.bindTarget(TARGET, "tex");
		path.drawShader(COMPOSITE_PASS);
	}

	static function hasContext(mesh: MeshObject, name: String): Bool {
		for (mat in mesh.materials) {
			if (mat != null && mat.getContext(name) != null) return true;
		}
		return false;
	}
}
