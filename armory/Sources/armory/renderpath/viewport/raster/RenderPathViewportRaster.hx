package armory.renderpath.viewport.raster;

import armory.renderpath.viewport.ViewportTargets;
import armory.renderpath.viewport.ViewportCompositor;
import armory.renderpath.viewport.ViewportShaders;
import iron.RenderPath;

/**
	The Viewport (Eevee) renderer: a render path that imitates Blender's Eevee,
	driven by each scene's Eevee settings (RasterSettings). Iron calls commands()
	once per frame. A frame runs these passes in order:
	1. Lights: pack the scene's lights (RasterLights) and pick the lighting pass's version.
	2. Shadow atlas: draw the shadow casters into each light's views (RasterShadows).
	3. Material pass: the materials write the material images, vpraster_gbuffer0 to 4
	   (see Shaders/vpraster/materialx/arm_gbuffer.glsl). The fifth holds the screen motion.
	4. AOVs: only those the scene's compositor reads, each into vpraster_aov_<name>.
	5. Late materials: blended materials without alpha, into the material images.
	6. World pass: the sky's colour and motion where no surface is.
	7. Shadow pass: each pixel's shadows from up to 4 lights, into one image.
	8. Lighting pass: lights the material images into vpraster_hdr.
	9. Blended materials: drawn into their own target, then put over vpraster_hdr (RasterTransparency).
	10. Compositor: the scene's compositor nodes, Glare included (ViewportCompositor).
	11. TAA: blends the frame into the history (RasterTaa).
	12. Film: maps the result to the screen with Blender's colour management table.
	Before step 3, the camera is jittered for TAA (RasterTaa.begin()).
**/
class RenderPathViewportRaster {

	/** A material's pass writing an AOV is named AOV_CONTEXT[name] (see aovContext()). **/
	public static inline var AOV_CONTEXT = "vpraster_aov";
	/** The pass of blended materials without alpha, drawn into the material images after the AOVs (see RasterTransparency). **/
	public static inline var LATE_CONTEXT = "vpraster_late";
	/**
		The versions of the lighting pass, in the order of lighting.py VARIANTS. Each
		has only the code some frames need. The index is a sum of these bits:
		- OUTLINES: lamps drawn by their outline in highlights.
		- LOCAL_SHADOWS: shadows of spot, point and area lights.
		- FROM_SHADOW_PASS: shadows read from the shadow pass. That pass has every
		  light's shadow, so LOCAL_SHADOWS is not combined with it.
		See choosePasses().
	**/
	static var LIGHTING = [for (name in ["vpraster_lighting", "vpraster_lighting_outlines",
		"vpraster_lighting_local", "vpraster_lighting_outlines_local",
		"vpraster_lighting_shadowpass", "vpraster_lighting_outlines_shadowpass"]) ViewportShaders.handle(name)];
	static inline var OUTLINES = 1;
	static inline var LOCAL_SHADOWS = 2;
	static inline var FROM_SHADOW_PASS = 4;
	/** The versions of the shadow pass (lighting.py SHADOW_VARIANTS): suns only, then with spot, point and area lights. **/
	static var SHADOW_PASS = [ViewportShaders.handle("vpraster_shadow_pass"), ViewportShaders.handle("vpraster_shadow_pass_local")];
	/** The shadow pass's image: each pixel's visibility from up to 4 lights, one per channel (see RasterLights.shadowLights). **/
	public static inline var SHADOWS = "vpraster_shadows";

	/** The lit image: the sky, then every surface lit, then the blended ones over it. **/
	public static inline var HDR = "vpraster_hdr";
	/** The fifth material image: screen motion (xy) and specular IOR (z). TAA reads the motion. **/
	public static inline var MOTION = "vpraster_gbuffer4";
	/** The depth buffer of the material pass, and the name for sampling it (Iron binds a depth buffer as "_" + its name). **/
	public static inline var DEPTH = "vpraster_depth";
	public static inline var DEPTH_TEXTURE = "_vpraster_depth";

	static var path: RenderPath;
	static var skyOutputs = [HDR]; // the world pass's extra output, next to the motion (one list, reused every frame)
	static var taaTarget = 0; // which of vpraster_taa0 and vpraster_taa1 this frame writes; the other is the history
	static var taaImage: kha.Image = null; // the image and camera the history was made with
	static var taaCamera: iron.object.CameraObject = null;
	static var gbuffer = ["vpraster_gbuffer0", "vpraster_gbuffer1", "vpraster_gbuffer2", "vpraster_gbuffer3", MOTION];
	static var gbufferAttachments = gbuffer.slice(1); // drawn together with vpraster_gbuffer0
	static var gbufferUniforms = ["gbuffer0", "gbuffer1", "gbuffer2", "gbuffer3", "gbuffer4"]; // their samplers in the lighting pass
	static var taaTargets = ["vpraster_taa0", "vpraster_taa1"];
	static var sceneRawName: String = null; // the scene file the renderer was last asked to show
	static var sceneReady = false; // true once that scene's settings are applied (switchScene())
	static var aovTargets: Array<String> = []; // the AOVs the active scene's compositor reads
	static var aovContexts: Array<String> = [];
	static var compositorPasses = new Map<String, String>(); // render pass -> its target, for the compositor
	static var compositorTransparent = false; // whether the compositor reads the Transparent pass
	static var passesLoaded = new Map<String, Bool>(); // lighting and shadow passes asked for -> whether each has loaded
	static var passes = new PassChoice(); // the versions of the lighting and shadow passes this frame draws (choosePasses())

	public static function init(_path: RenderPath) {
		path = _path;
		RasterUniforms.register();
		ViewportCompositor.register();

		ViewportTargets.init(path, scale());
		path.createDepthBuffer(DEPTH, "DEPTH24");
		ViewportTargets.create(HDR); // no depth buffer: the lighting pass samples the depth while drawing here
		ViewportTargets.create("vpraster_gbuffer0", DEPTH);
		for (i in 1...gbuffer.length) ViewportTargets.create(gbuffer[i]);
		ViewportTargets.create("vpraster_taa0");
		ViewportTargets.create("vpraster_taa1");
		ViewportTargets.create(RasterTransparency.TARGET, DEPTH); // blended materials are depth-tested against the opaque surfaces

		path.loadShader("shader_datas/vpraster_world_pass/vpraster_world_pass");
		path.loadShader(RasterTransparency.COMPOSITE_PASS); // the lighting and shadow passes load later, when needed (choosePasses())
		path.loadShader("shader_datas/vpraster_taa_pass/vpraster_taa_pass");
		path.loadShader("shader_datas/vpraster_film_pass/vpraster_film_pass");
	}

	static inline function scale(): Float {
		return RasterSettings.current.resolution_percentage / 100.0;
	}

	public static function commands() {
		var scene = iron.Scene.active;
		if (scene == null || scene.camera == null) return; // nothing to draw yet (scene loading)
		updateScene(scene);
		if (!ready() || !prepareFrame(scene)) {
			drawBlank();
			return;
		}
		var sky = !RasterSettings.current.film_transparent && scene.world != null;
		if (!sky) clearBackground();
		drawMaterials();
		if (sky) drawSky();
		if (passes.shadowPass != null) drawShadowPass();
		drawLighting();
		var blended = drawTransparency();
		var image = drawCompositor(blended);
		var resolved = resolveTaa(image);
		finishFrame();
		drawFilm(resolved);
	}

	/** Starts applying the active scene's settings when the scene changes (switchScene() runs once they have loaded). **/
	static function updateScene(scene: iron.Scene) {
		if (scene.raw.name == sceneRawName) return;
		var raw = sceneRawName = scene.raw.name;
		sceneReady = false;
		RasterSettings.applyScene(sceneName(scene), function(film: String) {
			if (raw != sceneRawName) return; // another scene was asked for meanwhile
			switchScene(film);
			sceneReady = true;
		});
	}

	/**
		Whether the frame can be drawn.

		Krom loads files at once. A browser loads them only after the call that asks
		for them returns. So the frame stays black until the scene's settings, its
		colour table, the specular tables and every shader have loaded (switchScene()
		starts loading the compositor's).
	**/
	static inline function ready(): Bool {
		return sceneReady && RasterFilm.ready() && RasterUniforms.tablesReady() && path.ready;
	}

	/**
		Packs the lights, picks the versions of the lighting and shadow passes
		(choosePasses()), draws the shadow atlas, updates the world and frame
		uniforms, and jitters the camera for TAA. Returns false while no version of
		the lighting pass has loaded, before drawing anything.
	**/
	static function prepareFrame(scene: iron.Scene): Bool {
		RasterLights.update();
		if (choosePasses().lighting == null) return false;
		RasterShadows.render(path);
		RasterEnvironment.update();
		RasterUniforms.beginFrame();
		// The TAA history is dropped when the targets are made again, as on a window
		// resize (the new images hold nothing yet), or when another camera takes over
		// (the history shows another view).
		var hdr = path.renderTargets.get(HDR).image;
		if (hdr != taaImage || scene.camera != taaCamera) {
			taaImage = hdr;
			taaCamera = scene.camera;
			RasterTaa.reset();
		}
		RasterTaa.begin(hdr.width, hdr.height);
		return true;
	}

	/**
		Without a sky (no world, or Film Transparent), the motion and colour are
		cleared here. The material pass then overwrites the motion where it draws.
		The motion image is the first target, because vpraster_hdr is later drawn
		alone while the motion is read (see ViewportTargets, KHA-HTML5).
	**/
	static function clearBackground() {
		path.setTarget(MOTION, skyOutputs);
		path.clearTarget(RasterSettings.current.film_transparent ? 0x00000000 : 0xff000000); // no world: black, as in Blender
	}

	/** Draws the material images, then the AOVs the compositor reads, then the late materials. **/
	static function drawMaterials() {
		// Material pass. The colours are not cleared: later passes tell sky pixels apart by depth.
		setTargetMeshes();
		path.clearTarget(null, 1.0);
		path.drawMeshes("mesh");
		// AOVs are 0 where no material writes them, as in Eevee. They are depth-tested
		// against the material pass, so only the front-most surfaces write theirs.
		for (i in 0...aovTargets.length) {
			ViewportTargets.setAlone(path, aovTargets[i]);
			path.clearTarget(0x00000000);
			path.drawMeshes(aovContexts[i]);
		}
		// Blended materials without alpha are drawn after the AOVs, as Eevee does, so
		// they do not hide the AOVs of what is behind them. The lighting pass lights
		// them with the rest.
		setTargetMeshes();
		path.drawMeshes(LATE_CONTEXT);
	}

	/**
		World pass: the sky's colour and motion, drawn only where no surface is.
		Drawing it after the surfaces skips the pixels they cover.
	**/
	static function drawSky() {
		path.setTarget(MOTION, skyOutputs);
		path.bindTarget(DEPTH_TEXTURE, "gbufferDepth");
		path.drawShader("shader_datas/vpraster_world_pass/vpraster_world_pass");
	}

	/**
		Shadow pass: the shadows of every pixel with a surface, before lighting.
		The shadow code runs faster in a pass of its own than inside the lighting
		pass (see lighting.py).
	**/
	static function drawShadowPass() {
		ViewportTargets.ensure(SHADOWS);
		ViewportTargets.setAlone(path, SHADOWS);
		path.bindTarget(gbuffer[1], gbufferUniforms[1]);
		path.bindTarget(DEPTH_TEXTURE, "gbufferDepth");
		path.drawShader(passes.shadowPass);
	}

	/** Lighting pass: lights every pixel with a surface. The sky stays as the world pass drew it. **/
	static function drawLighting() {
		ViewportTargets.setAlone(path, HDR);
		for (i in 0...gbuffer.length) path.bindTarget(gbuffer[i], gbufferUniforms[i]);
		path.bindTarget(DEPTH_TEXTURE, "gbufferDepth");
		// The version that reads the shadow pass always gets an image for its sampler.
		// Without shadows this frame, it gets the motion image, which it never reads.
		// WebGL checks every sampler a shader declares, read or not: a sampler whose unit
		// still holds the target being drawn into makes it refuse the draw (a feedback loop).
		var lighting = passes.lighting;
		if (lighting == LIGHTING[FROM_SHADOW_PASS] || lighting == LIGHTING[FROM_SHADOW_PASS + OUTLINES]) {
			path.bindTarget(passes.shadowPass != null ? SHADOWS : MOTION, "u_armShadowVisibility");
		}
		path.drawShader(lighting);
	}

	/** Draws the blended materials and puts them over vpraster_hdr. Returns whether any were drawn. **/
	static function drawTransparency(): Bool {
		var blended = RasterTransparency.draw(path);
		if (blended) RasterTransparency.composite(path);
		return blended;
	}

	/**
		Compositor, on the scene-linear image as in Blender. It runs before temporal
		anti-aliasing, which then smooths the edges of its masks. Returns the target
		that holds the result. `blended` tells whether drawTransparency() drew anything.
	**/
	static function drawCompositor(blended: Bool): String {
		var image = HDR;
		if (ViewportCompositor.active) {
			if (compositorTransparent && !blended) { // nothing blended this frame: the Transparent pass is empty
				ViewportTargets.setAlone(path, RasterTransparency.TARGET);
				path.clearTarget(0x00000000);
			}
			image = ViewportCompositor.draw(path, image, RasterTaa.longNoiseFrame(), compositorPasses);
		}
		return image;
	}

	/** With TAA on, blends `image` into the history. Returns the target that holds the result. **/
	static function resolveTaa(image: String): String {
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
		return resolved;
	}

	/** Ends the frame's TAA and remembers the frame for the next one's motion vectors (the counterparts of prepareFrame()). **/
	static function finishFrame() {
		RasterTaa.end();
		RasterMotionHistory.endFrame();
	}

	/** Film: maps `image` to the screen with Blender's colour management table. **/
	static function drawFilm(image: String) {
		path.setTarget("");
		path.bindTarget(image, "tex");
		path.drawShader("shader_datas/vpraster_film_pass/vpraster_film_pass");
		path.endFrame(); // KHA-HTML5: closes the framebuffer so 2D drawing (UI) can begin (see RenderPath.endFrame())
	}

	static function drawBlank() {
		path.setTarget("");
		path.clearTarget(0xff000000);
		path.endFrame();
	}

	/**
		Picks the versions of the lighting pass and of the shadow pass before it with
		only the code this frame needs. Fills and returns `passes`. Its `lighting` is
		null while no version has loaded. Its `shadowPass` is null when the frame
		draws no shadow pass.

		With up to RasterLights.PASS_LIGHTS shadow-casting lights, the shadow pass
		draws their shadows and the lighting pass reads them. With more, the lighting
		pass looks every shadow up itself.

		Each version loads the first time it is needed, so a game only compiles what
		its scenes use. While it loads, a loaded version with all the needed code
		draws the same image. Failing that, any loaded version draws, with lamps as
		points and local lights unshadowed.
	**/
	static function choosePasses(): PassChoice {
		var outlines = RasterLights.outlines ? OUTLINES : 0;
		var needs = outlines | (RasterLights.localShadows ? LOCAL_SHADOWS : 0);
		passes.lighting = null;
		passes.shadowPass = null;
		if (RasterLights.shadowLights <= RasterLights.PASS_LIGHTS) {
			var lighting = LIGHTING[FROM_SHADOW_PASS + outlines];
			var lightingReady = requestPass(lighting);
			var shadows: String = null;
			var shadowsReady = true; // false while no version of the shadow pass this frame needs has loaded
			if (RasterLights.shadowLights != 0) {
				shadows = SHADOW_PASS[RasterLights.localShadows ? 1 : 0];
				// While the version with local shadows loads, the suns-only version draws without them.
				if (!requestPass(shadows)) {
					shadows = isLoaded(SHADOW_PASS[0]) ? SHADOW_PASS[0] : null;
					shadowsReady = shadows != null;
				}
			}
			if (lightingReady && shadowsReady) {
				passes.lighting = lighting;
				passes.shadowPass = shadows;
			}
			else {
				// Meanwhile, use a loaded version that looks the shadows up itself (without starting to load one)
				passes.lighting = loadedLighting(needs);
			}
			return passes;
		}
		if (requestPass(LIGHTING[needs])) passes.lighting = LIGHTING[needs];
		else {
			passes.lighting = loadedLighting(needs);
			if (passes.lighting == null) passes.lighting = loadedLighting(0); // any loaded version
		}
		return passes;
	}

	/**
		The first loaded version of the lighting pass with all the code in `needs`,
		among those that look the shadows up themselves. Null if none has loaded.
		Starts no loading.
	**/
	static function loadedLighting(needs: Int): String {
		for (version in 0...FROM_SHADOW_PASS) {
			if ((version & needs) == needs && isLoaded(LIGHTING[version])) return LIGHTING[version];
		}
		return null;
	}

	/** Whether a lighting or shadow pass has loaded. False if it was never asked for (requestPass()). **/
	static inline function isLoaded(handle: String): Bool {
		return passesLoaded.get(handle) == true;
	}

	/**
		Starts loading a lighting or shadow pass the first time it is asked for.
		Returns true once it can be drawn.

		In a browser the file loads asynchronously, and path.loadShader() alone would
		hold every frame (path.ready) until it is in. So the file loads through Data
		first, and the renderer draws with another loaded version meanwhile.
	**/
	static function requestPass(handle: String): Bool {
		var loaded = passesLoaded.get(handle);
		if (loaded != null) return loaded;
		passesLoaded.set(handle, false);
		var parts = handle.split("/");
		var file = parts[0];
		#if arm_json
		file += ".json";
		#end
		iron.data.Data.getShader(file, parts[1], function(_) {
			path.loadShader(handle); // already in Data's cache, so this finishes at once
			passesLoaded.set(handle, true);
		});
		return passesLoaded.get(handle); // already true on Krom, which loads at once
	}

	/** The exported scene name: the scene file's name without its format extension. **/
	static function sceneName(scene: iron.Scene): String {
		var name = scene.raw.name;
		for (ext in [".lz4", ".json", ".arm"]) {
			if (StringTools.endsWith(name, ext)) return name.substr(0, name.length - ext.length);
		}
		return name;
	}

	/**
		Switches to the new scene's own Eevee settings (RasterSettings, just applied)
		and its colour management table `film`, as Blender does. Called once the
		scene's settings have loaded.
	**/
	static function switchScene(film: String) {
		RasterFilm.load(film);
		ViewportTargets.setScale(scale());
		// Targets the last scene made and this one does not ask for are freed (see ViewportTargets)
		ViewportTargets.beginScene();
		RasterTransparency.reset();
		ViewportCompositor.setScene(path, RasterSettings.current.compositor);
		// Only the render passes the compositor reads are drawn (compositor.py).
		// An AOV costs a full mesh pass, and only the compositor reads AOVs (in Eevee
		// they are render passes). The stages name the AOVs aov0, aov1... in the
		// scene's order.
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
			ViewportTargets.ensure(aovTarget(aov), 1.0, DEPTH); // depth-tested against the material pass's surfaces
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

/** The versions of the lighting pass and of the shadow pass before it that a frame draws (see choosePasses()). **/
private class PassChoice {
	public var lighting: String = null; // null while no version has loaded
	public var shadowPass: String = null; // null when the frame draws no shadow pass

	public function new() {}
}
