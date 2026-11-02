package armory.renderpath.eevee;

import iron.RenderPath;

/**
	Render path driven by Blender's Eevee settings. Draws the scene into a
	linear HDR target, then the film pass maps it to the display.
**/
class RenderPathEevee {

	static var path: RenderPath;

	public static function init(_path: RenderPath) {
		path = _path;
		EeveeUniforms.register();

		path.createDepthBuffer("eevee_depth", "DEPTH24");

		var t = new RenderTargetRaw();
		t.name = "eevee_hdr";
		t.width = 0;
		t.height = 0;
		t.format = "RGBA64";
		t.depth_buffer = "eevee_depth";
		path.createRenderTarget(t);

		path.loadShader("shader_datas/eevee_world_pass/eevee_world_pass");
		path.loadShader("shader_datas/eevee_film_pass/eevee_film_pass");
	}

	public static function commands() {
		EeveeLights.update();
		EeveeUniforms.updateWorld();

		path.setTarget("eevee_hdr");
		path.clearTarget(null, 1.0);
		path.drawShader("shader_datas/eevee_world_pass/eevee_world_pass");
		path.setTarget("eevee_hdr"); // drawShader() ends the target
		path.drawMeshes("mesh");

		path.setTarget("");
		path.bindTarget("eevee_hdr", "tex");
		path.drawShader("shader_datas/eevee_film_pass/eevee_film_pass");
	}

	public static function setTargetMeshes() {
		path.setTarget("eevee_hdr");
	}

	public static function drawMeshes() {
		path.drawMeshes("mesh");
	}

	public static function applyConfig() {}
}
