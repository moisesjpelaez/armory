package armory.renderpath.viewport.raster;

import iron.RenderPath;
import iron.Scene;
import iron.object.MeshObject;

/**
	Blended materials (Render Method: Blended), drawn as Eevee draws them, as
	measured: after the opaque surfaces are lit and the AOVs written, each object
	lit in its own shader.

	Without alpha (mx_graph.py decides, as Eevee does) they are opaque: drawn
	first, near to far, hidden by and hiding other surfaces by depth. They are in
	the Transparent pass with full coverage, and they don't write AOVs, so the
	AOVs of what is behind them stay (OPAQUE_CONTEXT). They write the screen
	motion too, for temporal anti-aliasing.

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
	static var PASSES = [DEPTH_CONTEXT, BACK_CONTEXT, FRONT_CONTEXT, CONTEXT];
	public static inline var TARGET = "vpraster_transparent";
	public static inline var MOTION_TARGET = "vpraster_gbuffer4"; // the screen motion (RenderPathViewportRaster)
	public static inline var COMPOSITE_PASS = "shader_datas/vpraster_blend_pass/vpraster_blend_pass";

	static var NO_BIND_PARAMS: Array<String> = [];
	static var MOTION: Array<String> = [MOTION_TARGET];
	static var objects: Array<MeshObject> = [];
	static var depths: Array<Float> = [];
	static var order: Array<Int> = [];
	static var opaque: Array<MeshObject> = [];
	static var opaqueDepths: Array<Float> = [];
	static var opaqueOrder: Array<Int> = [];

	/** Draws the blended objects into TARGET; returns whether there were any. **/
	public static function draw(path: RenderPath): Bool {
		var camera = Scene.active.camera;
		var v = camera.V;
		objects.resize(0);
		depths.resize(0);
		order.resize(0);
		opaque.resize(0);
		opaqueDepths.resize(0);
		opaqueOrder.resize(0);
		for (mesh in Scene.active.meshes) {
			if (!mesh.visible) continue;
			var t = mesh.transform;
			// View-space z of the origin: more negative is farther. A mesh with both
			// kinds of materials is in both lists (each pass draws its own)
			var z = v._02 * t.worldx() + v._12 * t.worldy() + v._22 * t.worldz() + v._32;
			if (hasContext(mesh, OPAQUE_CONTEXT)) {
				opaqueDepths.push(z);
				opaqueOrder.push(opaque.length);
				opaque.push(mesh);
			}
			if (hasContext(mesh, CONTEXT) || hasContext(mesh, FRONT_CONTEXT)) {
				depths.push(z);
				order.push(objects.length);
				objects.push(mesh);
			}
		}
		if (objects.length == 0 && opaque.length == 0) return false;

		path.setTarget(TARGET);
		path.clearTarget(0x00000000); // colour only: the depth buffer holds the opaque surfaces
		if (opaque.length > 0) {
			// Near to far: the least shading hidden afterwards
			opaqueOrder.sort(function(a, b) return opaqueDepths[a] > opaqueDepths[b] ? -1 : opaqueDepths[a] < opaqueDepths[b] ? 1 : 0);
			path.setTarget(TARGET, MOTION);
			var g = path.currentG;
			for (i in opaqueOrder) opaque[i].render(g, OPAQUE_CONTEXT, NO_BIND_PARAMS);
			if (objects.length > 0) path.setTarget(TARGET);
		}
		if (objects.length > 0) {
			order.sort(function(a, b) return depths[a] < depths[b] ? -1 : depths[a] > depths[b] ? 1 : 0);
			var g = path.currentG;
			for (i in order) {
				var mesh = objects[i];
				for (pass in PASSES) if (hasContext(mesh, pass)) mesh.render(g, pass, NO_BIND_PARAMS);
			}
		}
		return true;
	}

	/** Puts TARGET over the lit image (vpraster_hdr): colour + lit * (1 - coverage). **/
	public static function composite(path: RenderPath) {
		path.setTarget("vpraster_hdr");
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
