package armory.renderpath.eevee;

import iron.RenderPath;
import iron.math.Vec4;

/**
	The active scene's compositor (blender/arm/eevee/compositor.py), drawn after
	the blended materials and before temporal anti-aliasing. It is a list of
	steps in drawing order:
	- a stage: a generated shader drawn into its target (the last one into
	  eevee_composite), reading the passes and the targets of earlier steps by name;
	- a Glare node: its highlights, levels and glare, drawn by the fixed passes
	  below at the node's Quality, read by later stages as glare<i> (the glare)
	  and glare<i>_hl (the highlights).
**/
class EeveeCompositor {

	public static inline var RESULT = "eevee_composite";
	static inline var MAX_LEVELS = 12; // the highlights and up to 11 blurred levels
	static inline var PREFILTER = "shader_datas/eevee_glare_prefilter/eevee_glare_prefilter";
	static inline var FIREFLY = "shader_datas/eevee_glare_firefly/eevee_glare_firefly";
	static inline var DOWN = "shader_datas/eevee_glare_down/eevee_glare_down";
	static inline var UP = "shader_datas/eevee_glare_up/eevee_glare_up";
	static inline var BLOOM = "shader_datas/eevee_glare_bloom/eevee_glare_bloom";

	// Uniforms of the Glare pass being drawn (EeveeUniforms links)
	public static var glare0 = new Vec4(); // threshold, smoothness, maximum (negative: no clamp), quality factor
	public static var glare1 = new Vec4(); // strength, saturation, 1 / levels, levels
	public static var glareTint = new Vec4(1, 1, 1, 1);

	static var steps: Array<Dynamic> = [];
	static var stageShaders: Array<String> = [];
	static var targets: Array<String> = []; // every target a step writes, bound to later stages by name
	static var uniforms: Array<String> = [];

	public static var active(get, never): Bool;
	static inline function get_active(): Bool return steps.length > 0;

	/** The steps of a scene (EeveeSettings.compositor), or null for none. **/
	public static function setScene(path: RenderPath, raw: Dynamic) {
		steps = raw != null ? raw.steps : [];
		stageShaders = [];
		targets = [];
		uniforms = [];
		for (step in steps) {
			if (step.shader != null) {
				var handle = step.shader + "/" + step.shader + "/" + step.shader;
				path.loadShader(handle);
				stageShaders.push(handle);
				if (step.target != null) {
					RenderPathEevee.ensureTarget(targetName(step.target), 1.0);
					targets.push(targetName(step.target));
					uniforms.push(step.target);
				}
			}
			else {
				stageShaders.push(null);
				var i: Int = step.index;
				var factor = 1.0 / step.quality;
				RenderPathEevee.ensureTarget(targetName("glare" + i + "_hl"), factor);
				RenderPathEevee.ensureTarget(targetName("glare" + i), factor);
				targets.push(targetName("glare" + i + "_hl"));
				uniforms.push("glare" + i + "_hl");
				targets.push(targetName("glare" + i));
				uniforms.push("glare" + i);
			}
		}
		if (steps.length > 0) {
			RenderPathEevee.ensureTarget(RESULT, 1.0);
			for (pass in [PREFILTER, FIREFLY, DOWN, UP, BLOOM]) path.loadShader(pass);
		}
	}

	static inline function targetName(uniform: String): String {
		return "eevee_" + uniform;
	}

	static inline function level(glare: Int, k: Int): String {
		return "eevee_glare" + glare + "_l" + k;
	}

	/**
		Draws the steps; `bindPasses` binds the render passes (image, transparent,
		depth, AOVs) for a stage. Returns the target holding the result.
	**/
	public static function draw(path: RenderPath, bindPasses: Void->Void): String {
		for (s in 0...steps.length) {
			var step: Dynamic = steps[s];
			if (step.shader != null) {
				path.setTarget(step.target != null ? targetName(step.target) : RESULT);
				bindPasses();
				for (t in 0...targets.length) path.bindTarget(targets[t], uniforms[t]);
				path.drawShader(stageShaders[s]);
			}
			else {
				drawBloom(path, step);
			}
		}
		return RESULT;
	}

	static function drawBloom(path: RenderPath, step: Dynamic) {
		var i: Int = step.index;
		var input: String = step.input == "image" ? "eevee_hdr" : targetName(step.input);
		var hl = targetName("glare" + i + "_hl");
		glare0.set(step.threshold, step.smoothness, step.maximum, step.quality);
		var tint: Array<Float> = step.tint;
		glareTint.set(tint[0], tint[1], tint[2], 1.0);

		path.setTarget(hl);
		path.bindTarget(input, "tex");
		path.drawShader(PREFILTER);

		// Levels: floor(log2(size * the highlights' smaller side)), the highlights included
		var image = path.renderTargets.get(hl).image;
		var extent: Float = step.size * Math.min(image.width, image.height);
		var n = 0;
		while (n < MAX_LEVELS && Math.pow(2, n + 1) <= extent) n++;
		if (n < 1) n = 1;
		glare1.set(step.strength, step.saturation, 1.0 / n, n);

		var previous = hl;
		for (k in 1...n) {
			// Made when first needed: n keeps every level at 2 pixels or more
			RenderPathEevee.ensureTarget(level(i, k), 1.0 / (step.quality * (1 << k)));
			path.setTarget(level(i, k));
			path.bindTarget(previous, "tex");
			path.drawShader(k == 1 ? FIREFLY : DOWN);
			previous = level(i, k);
		}
		// Up from the coarsest level: each step adds the next finer level
		var summed = level(i, n - 1);
		var k = n - 2;
		while (k >= 1) {
			var target = "eevee_glare" + i + "_u" + k;
			RenderPathEevee.ensureTarget(target, 1.0 / (step.quality * (1 << k)));
			path.setTarget(target);
			path.bindTarget(summed, "tex");
			path.bindTarget(level(i, k), "level");
			path.drawShader(UP);
			summed = target;
			k--;
		}
		path.setTarget(targetName("glare" + i));
		path.bindTarget(hl, "hl");
		if (n > 1) path.bindTarget(summed, "up");
		path.drawShader(BLOOM);
	}
}
