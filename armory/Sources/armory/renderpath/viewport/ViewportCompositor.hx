package armory.renderpath.viewport;

import iron.RenderPath;
import iron.data.MaterialData;
import iron.math.Vec4;
import iron.object.Object;

/**
	The active scene's compositor (blender/arm/viewport/compositor.py), drawn after
	the blended materials and before temporal anti-aliasing. It is a list of
	steps in drawing order:
	- a stage: a generated shader drawn into its target (the last one into
	  viewport_composite), reading the passes and the targets of earlier steps by name;
	- a Glare node: its highlights, then its type's passes (Bloom, Streaks,
	  Simple Star, Sun Beams), drawn by the fixed passes below at the node's
	  Quality, read by later stages as glare<i> (the glare) and glare<i>_hl (the
	  highlights).
	It depends on no renderer: the renderer passes in its image, its frame number
	and how to bind its render passes (draw()), and its targets come from
	ViewportTargets, so another Viewport renderer can use it as it is.
**/
class ViewportCompositor {

	public static inline var RESULT = "viewport_composite";
	static inline var MAX_LEVELS = 12; // the highlights and up to 11 blurred levels
	static inline var PREFILTER = "shader_datas/viewport_glare_prefilter/viewport_glare_prefilter";
	static inline var FIREFLY = "shader_datas/viewport_glare_firefly/viewport_glare_firefly";
	static inline var DOWN = "shader_datas/viewport_glare_down/viewport_glare_down";
	static inline var UP = "shader_datas/viewport_glare_up/viewport_glare_up";
	static inline var BLOOM = "shader_datas/viewport_glare_bloom/viewport_glare_bloom";
	static inline var STREAK = "shader_datas/viewport_glare_streak/viewport_glare_streak";
	static inline var STREAK_ADD = "shader_datas/viewport_glare_streak/viewport_glare_streak_add";
	static inline var STAR = "shader_datas/viewport_glare_star/viewport_glare_star";
	static inline var STAR_ADD = "shader_datas/viewport_glare_star/viewport_glare_star_add";
	static inline var SUN = "shader_datas/viewport_glare_sun/viewport_glare_sun";
	static inline var FINISH = "shader_datas/viewport_glare_finish/viewport_glare_finish";
	static inline var SUN_SAMPLES = 64; // Sun Beams samples per pixel at most (jittered beyond)

	// Uniforms of the Glare pass being drawn (links registered by register())
	public static var glare0 = new Vec4(); // threshold, smoothness, maximum (negative: no clamp), quality factor
	public static var glare1 = new Vec4(); // strength, saturation, scale (Bloom: 1 / levels), Bloom: levels
	public static var glare2 = new Vec4(); // per type (Shaders/viewport_glare_streak, _star, _sun)
	public static var glare3 = new Vec4();
	public static var glareTint = new Vec4(1, 1, 1, 1);

	static var steps: Array<Dynamic> = [];
	static var stageShaders: Array<String> = [];
	static var targets: Array<String> = []; // every target a step writes, bound to later stages by name
	static var uniforms: Array<String> = [];
	static var frame = 0; // the renderer's frame number, for Sun Beams' noise
	static var registered = false;

	public static var active(get, never): Bool;
	static inline function get_active(): Bool return steps.length > 0;

	/** Registers the Glare passes' uniform links with Iron (once; the renderer's init()). **/
	public static function register() {
		if (registered) return;
		registered = true;
		if (iron.object.Uniforms.externalVec4Links == null) iron.object.Uniforms.externalVec4Links = [];
		iron.object.Uniforms.externalVec4Links.push(vec4Link);
	}

	static function vec4Link(object: Object, mat: MaterialData, link: String): Vec4 {
		return switch (link) {
			case "_viewportGlare0": glare0;
			case "_viewportGlare1": glare1;
			case "_viewportGlare2": glare2;
			case "_viewportGlare3": glare3;
			case "_viewportGlareTint": glareTint;
			default: null;
		}
	}

	/** The steps of a scene (its settings' compositor), or null for none. **/
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
					ViewportTargets.ensure(targetName(step.target), 1.0);
					targets.push(targetName(step.target));
					uniforms.push(step.target);
				}
			}
			else {
				stageShaders.push(null);
				var i: Int = step.index;
				var factor = 1.0 / step.quality;
				ViewportTargets.ensure(targetName("glare" + i + "_hl"), factor);
				ViewportTargets.ensure(targetName("glare" + i), factor);
				targets.push(targetName("glare" + i + "_hl"));
				uniforms.push("glare" + i + "_hl");
				targets.push(targetName("glare" + i));
				uniforms.push("glare" + i);
			}
		}
		if (steps.length > 0) {
			ViewportTargets.ensure(RESULT, 1.0);
			for (pass in [PREFILTER, FIREFLY, DOWN, UP, BLOOM, STREAK, STREAK_ADD, STAR, STAR_ADD, SUN, FINISH]) path.loadShader(pass);
		}
	}

	/** The target of a stage or Glare, read by later stages as `uniform`. **/
	static inline function targetName(uniform: String): String {
		return "viewport_" + uniform;
	}

	static inline function level(glare: Int, k: Int): String {
		return "viewport_glare" + glare + "_l" + k;
	}

	/**
		Draws the steps over the renderer's `image` (the render, a target name) in
		frame `frameNumber`; `bindPasses` binds the render passes (image, transparent,
		depth, AOVs) for a stage. Returns the target holding the result.
	**/
	public static function draw(path: RenderPath, image: String, frameNumber: Int, bindPasses: Void->Void): String {
		frame = frameNumber;
		for (s in 0...steps.length) {
			var step: Dynamic = steps[s];
			if (step.shader != null) {
				ViewportTargets.setAlone(path, step.target != null ? targetName(step.target) : RESULT);
				bindPasses();
				for (t in 0...targets.length) path.bindTarget(targets[t], uniforms[t]);
				path.drawShader(stageShaders[s]);
			}
			else {
				drawGlare(path, step, image);
			}
		}
		return RESULT;
	}

	/** A Glare node: its highlights at the node's Quality, then its type's passes into glare<i>. **/
	static function drawGlare(path: RenderPath, step: Dynamic, image: String) {
		var i: Int = step.index;
		var input: String = step.input == "image" ? image : targetName(step.input);
		var hl = targetName("glare" + i + "_hl");
		glare0.set(step.threshold, step.smoothness, step.maximum, step.quality);
		var tint: Array<Float> = step.tint;
		glareTint.set(tint[0], tint[1], tint[2], 1.0);

		ViewportTargets.setAlone(path, hl);
		path.bindTarget(input, "tex");
		path.drawShader(PREFILTER);

		switch ((step.glare: String)) {
			case "bloom": drawBloom(path, step, i, hl);
			case "streaks": drawStreaks(path, step, i, hl);
			case "simple_star": drawStar(path, step, i, hl);
			case "sun_beams": drawSunBeams(path, step, i, hl);
		}
	}

	/**
		Pixels of the glare image per pixel of Blender's (Streaks and Simple Star
		are measured in pixels): the window over the render resolution, so the
		glare keeps its look at any window size.
	**/
	static function pixelScale(path: RenderPath, step: Dynamic, hl: String): Float {
		var image = path.renderTargets.get(hl).image;
		var blender: Float = step.render_size / step.quality;
		return blender > 0 ? Math.min(image.width, image.height) / blender : 1.0;
	}

	static inline function temporary(i: Int, k: Int): String {
		return "viewport_glare" + i + "_t" + k;
	}

	/** glare<i> of a summed type: `sum` scaled, then Saturation, Tint and Strength. **/
	static function finish(path: RenderPath, step: Dynamic, i: Int, sum: String, scale: Float) {
		glare1.set(step.strength, step.saturation, scale, 0);
		ViewportTargets.setAlone(path, targetName("glare" + i));
		path.bindTarget(sum, "tex");
		path.drawShader(FINISH);
	}

	/** Targets at the highlights' resolution: two to alternate between, and the sum (cleared). **/
	static function summingTargets(path: RenderPath, step: Dynamic, i: Int): Array<String> {
		var names = [temporary(i, 0), temporary(i, 1), temporary(i, 2)];
		for (name in names) ViewportTargets.ensure(name, 1.0 / step.quality);
		ViewportTargets.setAlone(path, names[2]);
		path.clearTarget(0x00000000);
		return names;
	}

	/** Each streak: iterations passes of four taps, steps 1, 4, 16...; the last one adds it to the sum. **/
	static function drawStreaks(path: RenderPath, step: Dynamic, i: Int, hl: String) {
		var t = summingTargets(path, step, i);
		var iterations: Int = step.iterations;
		var count: Int = step.streaks;
		var scale = pixelScale(path, step, hl);
		for (s in 0...count) {
			var angle: Float = step.angle + 2 * Math.PI * s / count;
			var source = hl;
			for (pass in 0...iterations) {
				var distance = Math.pow(4, pass);
				glare2.set(Math.cos(angle) * distance * scale, Math.sin(angle) * distance * scale, Math.pow(step.fade, distance), 0);
				glare3.set(Math.pow(step.color_modulation, pass + 1), 0, 0, 0);
				var last = pass == iterations - 1;
				var target = last ? t[2] : t[pass % 2];
				ViewportTargets.setAlone(path, target);
				path.bindTarget(source, "tex");
				path.drawShader(last ? STREAK_ADD : STREAK);
				source = target;
			}
		}
		finish(path, step, i, t[2], 1.0 / (8 * iterations));
	}

	/** Each line: iterations - 1 passes of the star's kernel, steps 1, 2, 3...; the last one adds it to the sum. **/
	static function drawStar(path: RenderPath, step: Dynamic, i: Int, hl: String) {
		var t = summingTargets(path, step, i);
		var fade: Float = step.fade;
		var a = fade / 2;
		var q = (2 - fade) * (1 - a) / (1 + a);
		var passes = (step.iterations: Int) - 1;
		var scale = pixelScale(path, step, hl);
		var lines = step.diagonal ? [[1.0, 1.0], [1.0, -1.0]] : [[1.0, 0.0], [0.0, 1.0]];
		for (line in lines) {
			var source = hl;
			for (pass in 0...passes) {
				var distance = (pass + 1) * scale;
				glare2.set(line[0] * distance, line[1] * distance, a, q);
				glare3.set(q - (1 - fade), 0, 0, 0);
				var last = pass == passes - 1;
				var target = last ? t[2] : t[pass % 2];
				ViewportTargets.setAlone(path, target);
				path.bindTarget(source, "tex");
				path.drawShader(last ? STAR_ADD : STAR);
				source = target;
			}
		}
		finish(path, step, i, t[2], 1.0);
	}

	/** Rays towards the sun position, at most Size x the image diagonal long. **/
	static function drawSunBeams(path: RenderPath, step: Dynamic, i: Int, hl: String) {
		var t = temporary(i, 2);
		ViewportTargets.ensure(t, 1.0 / step.quality);
		var image = path.renderTargets.get(hl).image;
		var position: Array<Float> = step.sun_position;
		var diagonal = Math.sqrt(image.width * image.width + image.height * image.height);
		glare2.set(position[0], position[1], step.size * diagonal, frame % 1024);
		glare3.set(SUN_SAMPLES, 0, 0, 0);
		ViewportTargets.setAlone(path, t);
		path.bindTarget(hl, "tex");
		path.drawShader(SUN);
		finish(path, step, i, t, 1.0);
	}

	static function drawBloom(path: RenderPath, step: Dynamic, i: Int, hl: String) {
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
			ViewportTargets.ensure(level(i, k), 1.0 / (step.quality * (1 << k)));
			ViewportTargets.setAlone(path, level(i, k));
			path.bindTarget(previous, "tex");
			path.drawShader(k == 1 ? FIREFLY : DOWN);
			previous = level(i, k);
		}
		// Up from the coarsest level: each step adds the next finer level
		var summed = level(i, n - 1);
		var k = n - 2;
		while (k >= 1) {
			var target = "viewport_glare" + i + "_u" + k;
			ViewportTargets.ensure(target, 1.0 / (step.quality * (1 << k)));
			ViewportTargets.setAlone(path, target);
			path.bindTarget(summed, "tex");
			path.bindTarget(level(i, k), "level");
			path.drawShader(UP);
			summed = target;
			k--;
		}
		ViewportTargets.setAlone(path, targetName("glare" + i));
		path.bindTarget(hl, "hl");
		if (n > 1) path.bindTarget(summed, "up");
		path.drawShader(BLOOM);
	}
}
