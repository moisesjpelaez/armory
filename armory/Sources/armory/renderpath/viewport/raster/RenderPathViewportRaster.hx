package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import armory.renderpath.viewport.ViewportCompositor;
import iron.RenderPath;

/**
	Render path driven by Blender's Eevee settings. Draws the sky into a linear
	HDR target (plus screen motion), the scene's materials into the material
	images (vpraster_gbuffer0 to 4, see Shaders/vpraster/materialx/arm_gbuffer.glsl;
	vpraster_gbuffer4 holds the screen motion) and the AOVs its compositor reads into
	theirs (vpraster_aov_<name>), lights them, draws the blended materials over the result
	(RasterTransparency), runs the scene's compositor on it (into viewport_composite),
	resolves temporal anti-aliasing, then the film pass maps the result to the
	display.
**/
class RenderPathViewportRaster {

	/** A material's pass writing an AOV: AOV_CONTEXT[name] (aovContext()). **/
	public static inline var AOV_CONTEXT = "vpraster_aov";
	/** Blended materials without alpha into the material images, after the AOVs (RasterTransparency). **/
	public static inline var LATE_CONTEXT = "vpraster_late";
	/**
		The lighting pass's versions (lighting.py VARIANTS), indexed by what a frame
		needs: 1 = lamp outlines (RasterLights.outlines), 2 = spot/point/area shadows
		(RasterLights.localShadows). See lightingPass().
	**/
	static var LIGHTING = [for (name in ["vpraster_lighting_points_sun", "vpraster_lighting_sun",
		"vpraster_lighting_points", "vpraster_lighting_pass"]) name + "/" + name + "/" + name];

	/** The lit image: the sky, then every surface lit, then the blended ones over it. **/
	public static inline var HDR = "vpraster_hdr";
	/** The screen motion (xy) and specular IOR (z): the material images' fifth, read by TAA. **/
	public static inline var MOTION = "vpraster_gbuffer4";
	/** The depth buffer of the material pass, and its name for sampling it (Iron binds "_" + a depth buffer). **/
	public static inline var DEPTH = "vpraster_depth";
	public static inline var DEPTH_TEXTURE = "_vpraster_depth";

	static var path: RenderPath;
	static var worldOutputs = [HDR]; // the world pass draws the motion and the sky colour (not made every frame)
	static var taaTarget = 0; // history ping-pong: vpraster_taa0 / vpraster_taa1
	static var taaImage: kha.Image = null; // the image and camera the history was made with
	static var taaCamera: iron.object.CameraObject = null;
	static var gbuffer = ["vpraster_gbuffer0", "vpraster_gbuffer1", "vpraster_gbuffer2", "vpraster_gbuffer3", MOTION];
	static var gbufferAttachments = gbuffer.slice(1); // drawn together with vpraster_gbuffer0
	static var gbufferUniforms = ["gbuffer0", "gbuffer1", "gbuffer2", "gbuffer3", "gbuffer4"]; // lighting pass
	static var taaTargets = ["vpraster_taa0", "vpraster_taa1"];
	static var sceneRawName: String = null; // scene file the renderer was last asked to show
	static var sceneReady = false; // its settings are applied (switchScene())
	static var aovTargets: Array<String> = []; // the active scene's AOVs its compositor reads
	static var aovContexts: Array<String> = [];
	static var compositorPasses = new Map<String, String>(); // render pass -> its target, for the compositor
	static var compositorTransparent = false; // the compositor reads the Transparent pass
	static var lightingLoaded = new Map<String, Bool>(); // lighting passes asked for: whether each is in

	public static function init(_path: RenderPath) {
		path = _path;
		RasterUniforms.register();
		ViewportCompositor.register();

		ViewportTargets.init(path, scale());
		path.createDepthBuffer(DEPTH, "DEPTH24");
		ViewportTargets.create(HDR); // no depth: the lighting pass reads the depth while drawing here
		ViewportTargets.create("vpraster_gbuffer0", DEPTH);
		for (i in 1...gbuffer.length) ViewportTargets.create(gbuffer[i]);
		ViewportTargets.create("vpraster_taa0");
		ViewportTargets.create("vpraster_taa1");
		ViewportTargets.create(RasterTransparency.TARGET, DEPTH); // tested against the opaque surfaces

		path.loadShader("shader_datas/vpraster_world_pass/vpraster_world_pass");
		path.loadShader(RasterTransparency.COMPOSITE_PASS); // the lighting pass: lightingPass()
		path.loadShader("shader_datas/vpraster_taa_pass/vpraster_taa_pass");
		path.loadShader("shader_datas/vpraster_film_pass/vpraster_film_pass");
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
			drawBlank();
			return;
		}

		RasterLights.update();
		var lighting = lightingPass();
		if (lighting == null) {
			drawBlank();
			return;
		}
		RasterShadows.render(path);
		RasterUniforms.updateWorld();
		RasterUniforms.beginFrame();
		// TAA history is dropped when the targets are made again (window resize: new,
		// uninitialized images) or another camera takes over (its motion has no history)
		var hdr = path.renderTargets.get(HDR).image;
		if (hdr != taaImage || scene.camera != taaCamera) {
			taaImage = hdr;
			taaCamera = scene.camera;
			RasterTaa.reset();
		}
		RasterTaa.begin(hdr.width, hdr.height);

		// Sky motion and colour; the material pass overwrites the motion where it draws.
		// The motion image goes first: vpraster_hdr is drawn alone later while the
		// motion is read (ViewportTargets: first targets of passes with extra outputs)
		path.setTarget(MOTION, worldOutputs);
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
		ViewportTargets.setAlone(path, HDR);
		for (i in 0...gbuffer.length) path.bindTarget(gbuffer[i], gbufferUniforms[i]);
		path.bindTarget(DEPTH_TEXTURE, "gbufferDepth");
		path.drawShader(lighting);

		var blended = RasterTransparency.draw(path);
		if (blended) RasterTransparency.composite(path);

		// Compositor, on the scene-linear image like Blender's; before temporal
		// anti-aliasing, which then smooths the edges of its masks
		var image = HDR;
		if (ViewportCompositor.active) {
			if (compositorTransparent && !blended) { // its Transparent pass: nothing blended this frame
				ViewportTargets.setAlone(path, RasterTransparency.TARGET);
				path.clearTarget(0x00000000);
			}
			image = ViewportCompositor.draw(path, image, RasterTaa.frame, compositorPasses);
		}

		var resolved = image;
		if (RasterTaa.enabled) {
			var output = taaTargets[taaTarget];
			var history = taaTargets[1 - taaTarget];
			ViewportTargets.setAlone(path, output);
			path.bindTarget(image, "tex");
			path.bindTarget(history, "history");
			path.bindTarget(MOTION, "velocity");
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

	static function drawBlank() {
		path.setTarget("");
		path.clearTarget(0xff000000);
		path.endFrame();
	}

	/**
		The lighting pass to draw: the version with only the code this frame needs (lamp
		outlines, spot/point/area shadows). Each is loaded the first time it is needed,
		so a game only compiles what its scenes use. Until it is in, a loaded version
		with all that code draws the same image; failing that, any loaded one draws
		(lamps as points, local lights unshadowed). Null while none is.
	**/
	static function lightingPass(): String {
		var needs = (RasterLights.outlines ? 1 : 0) | (RasterLights.localShadows ? 2 : 0);
		if (requestLighting(LIGHTING[needs])) return LIGHTING[needs];
		for (version in 0...LIGHTING.length) {
			if ((version & needs) == needs && lightingLoaded.get(LIGHTING[version]) == true) return LIGHTING[version];
		}
		for (handle in LIGHTING) if (lightingLoaded.get(handle) == true) return handle;
		return null;
	}

	/**
		Starts loading a lighting pass the first time it is asked for; true once it can
		be drawn. Through Data first: path.loadShader() alone would hold every frame
		(path.ready) until the file is in.
	**/
	static function requestLighting(handle: String): Bool {
		var loaded = lightingLoaded.get(handle);
		if (loaded != null) return loaded;
		lightingLoaded.set(handle, false);
		var parts = handle.split("/");
		var file = parts[0];
		#if arm_json
		file += ".json";
		#end
		iron.data.Data.getShader(file, parts[1], function(_) {
			path.loadShader(handle); // in Data's cache: done at once
			lightingLoaded.set(handle, true);
		});
		return lightingLoaded.get(handle); // Krom loads at once
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
		ViewportTargets.setScale(scale());
		// The scene's targets (ViewportTargets): what the last scene made and this one
		// doesn't ask for goes
		ViewportTargets.beginScene();
		RasterTransparency.reset();
		ViewportCompositor.setScene(path, RasterSettings.compositor);
		// The render passes its compositor reads (compositor.py): only those are drawn.
		// An AOV is a full mesh pass, and nothing else reads it (Eevee's AOVs are
		// render passes); its stages call AOVs aov0, aov1... in the scene's order
		compositorPasses = new Map();
		compositorPasses.set("depth", DEPTH_TEXTURE);
		compositorPasses.set("transparent", RasterTransparency.TARGET);
		compositorTransparent = ViewportCompositor.reads("transparent");
		aovTargets = [];
		aovContexts = [];
		for (i in 0...RasterSettings.aovNames.length) {
			if (!ViewportCompositor.reads("aov" + i)) continue;
			var aov = RasterSettings.aovNames[i];
			aovTargets.push(aovTarget(aov));
			aovContexts.push(aovContext(aov));
			compositorPasses.set("aov" + i, aovTarget(aov));
			ViewportTargets.ensure(aovTarget(aov), 1.0, DEPTH); // tested against the material pass's surfaces
		}
		ViewportTargets.endScene();
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
