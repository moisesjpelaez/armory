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

	public static function init(_path: RenderPath) {
		path = _path;
		EeveeSettings.load(function() {});
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
		EeveeLights.update();
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

	public static function setTargetMeshes() {
		path.setTarget("eevee_hdr", ["eevee_velocity"]);
	}

	public static function drawMeshes() {
		path.drawMeshes("mesh");
	}

	public static function applyConfig() {}
}
