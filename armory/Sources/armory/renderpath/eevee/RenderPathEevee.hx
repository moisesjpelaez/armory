package armory.renderpath.eevee;

import iron.RenderPath;

/**
	Render path driven by Blender's Eevee settings. Draws the sky into a linear
	HDR target (plus screen motion), the scene's materials into the material
	images (eevee_gbuffer0 to 4, see Shaders/eevee/materialx/arm_gbuffer.glsl;
	eevee_gbuffer4 holds the screen motion) and the scene's AOVs into theirs
	(eevee_aov_<name>), lights them, draws the blended materials over the result
	(EeveeTransparency), resolves temporal anti-aliasing, then the film pass maps
	the result to the display.
**/
class RenderPathEevee {

	/** A material's pass writing an AOV: AOV_CONTEXT[name] (aovContext()). **/
	public static inline var AOV_CONTEXT = "eevee_aov";

	static var path: RenderPath;
	static var taaTarget = 0; // history ping-pong: eevee_taa0 / eevee_taa1
	static var gbuffer = ["eevee_gbuffer0", "eevee_gbuffer1", "eevee_gbuffer2", "eevee_gbuffer3", "eevee_gbuffer4"];
	static var gbufferAttachments = gbuffer.slice(1); // drawn together with eevee_gbuffer0
	static var gbufferUniforms = ["gbuffer0", "gbuffer1", "gbuffer2", "gbuffer3", "gbuffer4"]; // lighting pass
	static var taaTargets = ["eevee_taa0", "eevee_taa1"];
	static var sceneRawName: String = null; // scene file name the settings were applied for
	static var targets = ["eevee_hdr", "eevee_taa0", "eevee_taa1", EeveeTransparency.TARGET].concat(gbuffer);
	static var targetScale = 1.0;
	static var aovTargets: Array<String> = []; // the active scene's AOVs, as EeveeSettings lists them
	static var aovContexts: Array<String> = [];

	public static function init(_path: RenderPath) {
		path = _path;
		EeveeSettings.loadIndex();
		EeveeUniforms.register();

		path.createDepthBuffer("eevee_depth", "DEPTH24");
		createTarget("eevee_hdr"); // no depth: the lighting pass reads eevee_depth while drawing here
		createTarget("eevee_gbuffer0", "eevee_depth");
		for (i in 1...gbuffer.length) createTarget(gbuffer[i]);
		createTarget("eevee_taa0");
		createTarget("eevee_taa1");
		createTarget(EeveeTransparency.TARGET, "eevee_depth"); // tested against the opaque surfaces

		path.loadShader("shader_datas/eevee_world_pass/eevee_world_pass");
		path.loadShader("eevee_lighting_pass/eevee_lighting_pass/eevee_lighting_pass");
		path.loadShader(EeveeTransparency.COMPOSITE_PASS);
		path.loadShader("shader_datas/eevee_taa_pass/eevee_taa_pass");
		path.loadShader("shader_datas/eevee_film_pass/eevee_film_pass");
	}

	static function createTarget(name: String, depthBuffer: String = null) {
		var t = new RenderTargetRaw();
		t.name = name;
		t.width = 0;
		t.height = 0;
		t.format = "RGBA64";
		t.scale = scale();
		t.depth_buffer = depthBuffer;
		path.createRenderTarget(t);
	}

	static inline function scale(): Float {
		return EeveeSettings.resolutionPercentage / 100.0;
	}

	public static function commands() {
		var scene = iron.Scene.active;
		if (scene == null || scene.camera == null) return; // nothing to draw yet (scene loading)
		if (scene.raw.name != sceneRawName) {
			sceneRawName = scene.raw.name;
			switchScene(sceneName(scene));
		}

		EeveeLights.update();
		EeveeShadows.render(path);
		EeveeUniforms.updateWorld();
		EeveeTaa.begin(iron.App.w() * scale(), iron.App.h() * scale());

		// Sky colour and motion; the material pass overwrites the motion where it draws
		path.setTarget("eevee_hdr", ["eevee_gbuffer4"]);
		if (EeveeSettings.filmTransparent) {
			path.clearTarget(0x00000000);
		}
		else if (scene.world == null) {
			path.clearTarget(0xff000000); // no world: black, as in Blender
		}
		else {
			path.drawShader("shader_datas/eevee_world_pass/eevee_world_pass");
		}
		// Material images: colours are not cleared, sky pixels are told apart by depth
		setTargetMeshes();
		path.clearTarget(null, 1.0);
		path.drawMeshes("mesh");
		// AOVs: 0 where no material writes them, as in Eevee. Tested against the
		// material pass's depth, so only the surfaces in front write theirs
		for (i in 0...aovTargets.length) {
			path.setTarget(aovTargets[i]);
			path.clearTarget(0x00000000);
			path.drawMeshes(aovContexts[i]);
		}

		// Lights every pixel with a surface; the sky stays as the world pass drew it
		path.setTarget("eevee_hdr");
		for (i in 0...gbuffer.length) path.bindTarget(gbuffer[i], gbufferUniforms[i]);
		path.bindTarget("_eevee_depth", "gbufferDepth");
		path.drawShader("eevee_lighting_pass/eevee_lighting_pass/eevee_lighting_pass");

		if (EeveeTransparency.draw(path)) EeveeTransparency.composite(path);

		var resolved = "eevee_hdr";
		if (EeveeTaa.enabled) {
			var output = taaTargets[taaTarget];
			var history = taaTargets[1 - taaTarget];
			path.setTarget(output);
			path.bindTarget("eevee_hdr", "tex");
			path.bindTarget(history, "history");
			path.bindTarget("eevee_gbuffer4", "velocity");
			path.drawShader("shader_datas/eevee_taa_pass/eevee_taa_pass");
			resolved = output;
			taaTarget = 1 - taaTarget;
		}
		EeveeTaa.end();
		#if arm_skin
		EeveeUniforms.endFrame();
		#end

		path.setTarget("");
		path.bindTarget(resolved, "tex");
		path.drawShader("shader_datas/eevee_film_pass/eevee_film_pass");
	}

	/** Exported scene name: the scene file name without its format extension. **/
	static function sceneName(scene: iron.Scene): String {
		var name = scene.raw.name;
		for (ext in [".lz4", ".json", ".arm"]) {
			if (StringTools.endsWith(name, ext)) return name.substr(0, name.length - ext.length);
		}
		return name;
	}

	/** Uses the scene's own Eevee settings and colour management, as Blender does. **/
	static function switchScene(name: String) {
		EeveeUniforms.loadFilm(EeveeSettings.applyScene(name));
		var newScale = scale();
		if (newScale != targetScale) {
			targetScale = newScale;
			for (target in targets) path.renderTargets.get(target).raw.scale = newScale;
			path.resize();
		}
		// An image per AOV, made the first time a scene declares it
		aovTargets = [for (aov in EeveeSettings.aovNames) aovTarget(aov)];
		aovContexts = [for (aov in EeveeSettings.aovNames) aovContext(aov)];
		for (target in aovTargets) {
			if (path.renderTargets.exists(target)) continue;
			createTarget(target, "eevee_depth"); // tested against the material pass's surfaces
			targets.push(target);
		}
		EeveeTaa.reset();
	}

	public static inline function aovTarget(name: String): String {
		return "eevee_aov_" + name;
	}

	public static inline function aovContext(name: String): String {
		return AOV_CONTEXT + "[" + name + "]";
	}

	public static function setTargetMeshes() {
		path.setTarget("eevee_gbuffer0", gbufferAttachments);
	}

	public static function drawMeshes() {
		path.drawMeshes("mesh");
	}

	public static function applyConfig() {}
}
