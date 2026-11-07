package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import armory.renderpath.viewport.ViewportCompositor;
import iron.RenderPath;

/**
	Render path driven by Blender's Eevee settings. Draws the sky into a linear
	HDR target (plus screen motion), the scene's materials into the material
	images (vpraster_gbuffer0 to 4, see Shaders/vpraster/materialx/arm_gbuffer.glsl;
	vpraster_gbuffer4 holds the screen motion) and the scene's AOVs into theirs
	(vpraster_aov_<name>), lights them, draws the blended materials over the result
	(RasterTransparency), runs the scene's compositor on it (into viewport_composite),
	resolves temporal anti-aliasing, then the film pass maps the result to the
	display.
**/
class RenderPathViewportRaster {

	/** A material's pass writing an AOV: AOV_CONTEXT[name] (aovContext()). **/
	public static inline var AOV_CONTEXT = "vpraster_aov";
	/** Blended materials without alpha into the material images, after the AOVs (RasterTransparency). **/
	public static inline var LATE_CONTEXT = "vpraster_late";

	static var path: RenderPath;
	static var taaTarget = 0; // history ping-pong: vpraster_taa0 / vpraster_taa1
	static var taaImage: kha.Image = null; // the image and camera the history was made with
	static var taaCamera: iron.object.CameraObject = null;
	static var gbuffer = ["vpraster_gbuffer0", "vpraster_gbuffer1", "vpraster_gbuffer2", "vpraster_gbuffer3", "vpraster_gbuffer4"];
	static var gbufferAttachments = gbuffer.slice(1); // drawn together with vpraster_gbuffer0
	static var gbufferUniforms = ["gbuffer0", "gbuffer1", "gbuffer2", "gbuffer3", "gbuffer4"]; // lighting pass
	static var taaTargets = ["vpraster_taa0", "vpraster_taa1"];
	static var sceneRawName: String = null; // scene file the renderer was last asked to show
	static var sceneReady = false; // its settings are applied (switchScene())
	static var targets = new Map<String, Float>(); // every target: its size relative to the scaled window
	static var targetScale = 1.0;
	static var aovTargets: Array<String> = []; // the active scene's AOVs, as RasterSettings lists them
	static var aovContexts: Array<String> = [];
	static var aovSamplers: Array<String> = []; // the compositor's AOV inputs: aov0, aov1...

	public static function init(_path: RenderPath) {
		path = _path;
		RasterUniforms.register();

		path.createDepthBuffer("vpraster_depth", "DEPTH24");
		createTarget("vpraster_hdr"); // no depth: the lighting pass reads vpraster_depth while drawing here
		createTarget("vpraster_gbuffer0", "vpraster_depth");
		for (i in 1...gbuffer.length) createTarget(gbuffer[i]);
		createTarget("vpraster_taa0");
		createTarget("vpraster_taa1");
		createTarget(RasterTransparency.TARGET, "vpraster_depth"); // tested against the opaque surfaces

		path.loadShader("shader_datas/vpraster_world_pass/vpraster_world_pass");
		path.loadShader("vpraster_lighting_pass/vpraster_lighting_pass/vpraster_lighting_pass");
		path.loadShader(RasterTransparency.COMPOSITE_PASS);
		path.loadShader("shader_datas/vpraster_taa_pass/vpraster_taa_pass");
		path.loadShader("shader_datas/vpraster_film_pass/vpraster_film_pass");
	}

	/** A target `factor` times the size of the scaled window (Resolution %). **/
	static function createTarget(name: String, depthBuffer: String = null, factor = 1.0) {
		var t = new RenderTargetRaw();
		t.name = name;
		t.width = 0;
		t.height = 0;
		t.format = "RGBA64";
		t.scale = scale() * factor;
		t.depth_buffer = depthBuffer;
		path.createRenderTarget(t);
		targets.set(name, factor);
	}

	/** createTarget() the first time a target is needed. **/
	public static function ensureTarget(name: String, factor: Float, depthBuffer: String = null) {
		if (!path.renderTargets.exists(name)) createTarget(name, depthBuffer, factor);
	}

	static inline function scale(): Float {
		return RasterSettings.resolutionPercentage / 100.0;
	}

	public static function commands() {
		var scene = iron.Scene.active;
		if (scene == null || scene.camera == null) return; // nothing to draw yet (scene loading)
		if (scene.raw.name != sceneRawName) {
			var raw = sceneRawName = scene.raw.name;
			sceneReady = false;
			RasterSettings.applyScene(sceneName(scene), function(film: String) {
				if (raw != sceneRawName) return; // another scene was asked for since
				switchScene(film);
				sceneReady = true;
			});
		}
		// Files load at once on Krom, but only after the call asking for them in a
		// browser: nothing is drawn until the scene's settings, its colour table, the
		// specular tables and every shader (the compositor's load in switchScene) are in
		if (!sceneReady || !RasterUniforms.filmReady() || !RasterUniforms.tablesReady() || !path.ready) {
			path.setTarget("");
			path.clearTarget(0xff000000);
			path.endFrame();
			return;
		}

		RasterLights.update();
		RasterShadows.render(path);
		RasterUniforms.updateWorld();
		// TAA history is dropped when the targets are made again (window resize: new,
		// uninitialized images) or another camera takes over (its motion has no history)
		var hdr = path.renderTargets.get("vpraster_hdr").image;
		if (hdr != taaImage || scene.camera != taaCamera) {
			taaImage = hdr;
			taaCamera = scene.camera;
			RasterTaa.reset();
		}
		RasterTaa.begin(hdr.width, hdr.height);

		// Sky motion and colour; the material pass overwrites the motion where it draws.
		// The motion image goes first: vpraster_hdr is drawn alone later while the
		// motion is read (ViewportTargets: first targets of passes with extra outputs)
		path.setTarget("vpraster_gbuffer4", ["vpraster_hdr"]);
		if (RasterSettings.filmTransparent) {
			path.clearTarget(0x00000000);
		}
		else if (scene.world == null) {
			path.clearTarget(0xff000000); // no world: black, as in Blender
		}
		else {
			path.drawShader("shader_datas/vpraster_world_pass/vpraster_world_pass");
		}
		// Material images: colours are not cleared, sky pixels are told apart by depth
		setTargetMeshes();
		path.clearTarget(null, 1.0);
		path.drawMeshes("mesh");
		// AOVs: 0 where no material writes them, as in Eevee. Tested against the
		// material pass's depth, so only the surfaces in front write theirs
		for (i in 0...aovTargets.length) {
			ViewportTargets.setAlone(path, aovTargets[i]);
			path.clearTarget(0x00000000);
			path.drawMeshes(aovContexts[i]);
		}
		// Blended materials without alpha: drawn after the AOVs, as Eevee draws them
		// (they don't hide the AOVs of what is behind them), then lit with the rest
		setTargetMeshes();
		path.drawMeshes(LATE_CONTEXT);

		// Lights every pixel with a surface; the sky stays as the world pass drew it
		ViewportTargets.setAlone(path, "vpraster_hdr");
		for (i in 0...gbuffer.length) path.bindTarget(gbuffer[i], gbufferUniforms[i]);
		path.bindTarget("_vpraster_depth", "gbufferDepth");
		path.drawShader("vpraster_lighting_pass/vpraster_lighting_pass/vpraster_lighting_pass");

		var blended = RasterTransparency.draw(path);
		if (blended) RasterTransparency.composite(path);

		// Compositor, on the scene-linear image like Blender's; before temporal
		// anti-aliasing, which then smooths the edges of its masks
		var image = "vpraster_hdr";
		if (ViewportCompositor.active) {
			if (!blended) { // its Transparent pass: nothing blended this frame
				ViewportTargets.setAlone(path, RasterTransparency.TARGET);
				path.clearTarget(0x00000000);
			}
			image = ViewportCompositor.draw(path, bindPasses);
		}

		var resolved = image;
		if (RasterTaa.enabled) {
			var output = taaTargets[taaTarget];
			var history = taaTargets[1 - taaTarget];
			ViewportTargets.setAlone(path, output);
			path.bindTarget(image, "tex");
			path.bindTarget(history, "history");
			path.bindTarget("vpraster_gbuffer4", "velocity");
			path.drawShader("shader_datas/vpraster_taa_pass/vpraster_taa_pass");
			resolved = output;
			taaTarget = 1 - taaTarget;
		}
		RasterTaa.end();
		RasterUniforms.endFrame();

		path.setTarget("");
		path.bindTarget(resolved, "tex");
		path.drawShader("shader_datas/vpraster_film_pass/vpraster_film_pass");
		path.endFrame(); // 2D drawing (UI) comes next: it needs the framebuffer closed in a browser
	}

	/** The render passes a compositor stage reads (compositor.py). **/
	static function bindPasses() {
		path.bindTarget("vpraster_hdr", "image");
		path.bindTarget(RasterTransparency.TARGET, "transparent");
		path.bindTarget("_vpraster_depth", "depth");
		for (i in 0...aovTargets.length) path.bindTarget(aovTargets[i], aovSamplers[i]);
	}

	/** Exported scene name: the scene file name without its format extension. **/
	static function sceneName(scene: iron.Scene): String {
		var name = scene.raw.name;
		for (ext in [".lz4", ".json", ".arm"]) {
			if (StringTools.endsWith(name, ext)) return name.substr(0, name.length - ext.length);
		}
		return name;
	}

	/**
		Uses the scene's own Eevee settings (RasterSettings, just applied) and colour
		management table `film`, as Blender does.
	**/
	static function switchScene(film: String) {
		RasterUniforms.loadFilm(film);
		var newScale = scale();
		if (newScale != targetScale) {
			targetScale = newScale;
			for (target => factor in targets) path.renderTargets.get(target).raw.scale = newScale * factor;
			path.resize();
		}
		// An image per AOV, made the first time a scene declares it
		aovTargets = [for (aov in RasterSettings.aovNames) aovTarget(aov)];
		aovContexts = [for (aov in RasterSettings.aovNames) aovContext(aov)];
		aovSamplers = [for (i in 0...aovTargets.length) "aov" + i];
		for (target in aovTargets) ensureTarget(target, 1.0, "vpraster_depth"); // tested against the material pass's surfaces
		ViewportCompositor.setScene(path, RasterSettings.compositor);
		RasterTaa.reset();
	}

	public static inline function aovTarget(name: String): String {
		return "vpraster_aov_" + name;
	}

	public static inline function aovContext(name: String): String {
		return AOV_CONTEXT + "[" + name + "]";
	}

	public static function setTargetMeshes() {
		path.setTarget("vpraster_gbuffer0", gbufferAttachments);
	}

	public static function drawMeshes() {
		path.drawMeshes("mesh");
	}

	public static function applyConfig() {}
}
