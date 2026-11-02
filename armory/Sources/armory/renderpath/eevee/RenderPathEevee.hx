package armory.renderpath.eevee;

import iron.RenderPath;

/**
	Render path driven by Blender's Eevee settings. Draws the sky and the scene
	into a linear HDR target (plus screen motion), resolves temporal
	anti-aliasing, then the film pass maps the result to the display.
**/
class RenderPathEevee {

	static var path: RenderPath;
	static var taaTarget = 0; // history ping-pong: eevee_taa0 / eevee_taa1
	static var targets = ["eevee_hdr", "eevee_velocity", "eevee_taa0", "eevee_taa1"];
	static var targetScale = 1.0;

	public static function init(_path: RenderPath) {
		path = _path;
		EeveeSettings.loadIndex();
		EeveeUniforms.register();

		path.createDepthBuffer("eevee_depth", "DEPTH24");
		createTarget("eevee_hdr", "eevee_depth");
		createTarget("eevee_velocity");
		createTarget("eevee_taa0");
		createTarget("eevee_taa1");

		path.loadShader("shader_datas/eevee_world_pass/eevee_world_pass");
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
		if (scene != null && sceneName(scene) != EeveeSettings.sceneName) switchScene(sceneName(scene));

		EeveeLights.update();
		EeveeShadows.render(path);
		EeveeUniforms.updateWorld();
		EeveeTaa.begin(iron.App.w() * scale(), iron.App.h() * scale());

		setTargetMeshes();
		if (EeveeSettings.filmTransparent) {
			path.clearTarget(0x00000000, 1.0);
		}
		else {
			path.clearTarget(null, 1.0);
			path.drawShader("shader_datas/eevee_world_pass/eevee_world_pass");
			setTargetMeshes(); // drawShader() ends the target
		}
		path.drawMeshes("mesh");

		var resolved = "eevee_hdr";
		if (EeveeTaa.enabled) {
			var output = "eevee_taa" + taaTarget;
			var history = "eevee_taa" + (1 - taaTarget);
			path.setTarget(output);
			path.bindTarget("eevee_hdr", "tex");
			path.bindTarget(history, "history");
			path.bindTarget("eevee_velocity", "velocity");
			path.drawShader("shader_datas/eevee_taa_pass/eevee_taa_pass");
			resolved = output;
			taaTarget = 1 - taaTarget;
		}
		EeveeTaa.end();

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
		var table = EeveeSettings.applyScene(name);
		if (table != null) EeveeUniforms.loadFilm(table);
		var newScale = scale();
		if (newScale != targetScale) {
			targetScale = newScale;
			for (target in targets) path.renderTargets.get(target).raw.scale = newScale;
			path.resize();
		}
		EeveeTaa.reset();
	}

	public static function setTargetMeshes() {
		path.setTarget("eevee_hdr", ["eevee_velocity"]);
	}

	public static function drawMeshes() {
		path.drawMeshes("mesh");
	}

	public static function applyConfig() {}
}
