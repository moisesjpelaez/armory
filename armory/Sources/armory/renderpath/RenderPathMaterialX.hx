package armory.renderpath;

import iron.RenderPath;
import iron.Scene;

class RenderPathMaterialX {

	#if (rp_renderer == "MaterialX")

	static var path: RenderPath;

	public static function setTargetMeshes() {
		path.setTarget("");
	}

	public static function drawMeshes() {
		path.drawMeshes("mesh");

		#if rp_blending
		{
			path.drawMeshes("blend");
		}
		#end

		#if (rp_background == "World")
		{
			if (Scene.active.raw.world_ref != null) {
				RenderPathCreator.setTargetMeshes();
				path.drawSkydome("shader_datas/World_" + Scene.active.raw.world_ref + "/World_" + Scene.active.raw.world_ref);
			}
		}
		#end
	}

	public static function applyConfig() {
		Inc.applyConfig();
	}

	public static function init(_path: RenderPath) {
		path = _path;
	}

	public static function commands() {
		#if rp_shadowmap
		{
			#if arm_shadowmap_atlas
			Inc.drawShadowMapAtlas();
			#else
			Inc.drawShadowMap();
			#end
		}
		#end

		RenderPathCreator.setTargetMeshes();

		#if (rp_background == "Clear")
		{
			path.clearTarget(-1, 1.0);
		}
		#else
		{
			path.clearTarget(null, 1.0);
		}
		#end

		#if rp_shadowmap
		{
			#if arm_shadowmap_atlas
			Inc.bindShadowMapAtlas();
			#else
			Inc.bindShadowMap();
			#end
		}
		#end

		RenderPathCreator.drawMeshes();
	}

	// Renders straight to the framebuffer, no depth texture yet
	public static function setupDepthTexture() {}

	#end
}
