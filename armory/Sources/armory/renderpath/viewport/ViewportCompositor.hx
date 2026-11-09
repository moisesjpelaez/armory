package armory.renderpath.viewport;

import iron.RenderPath;
import iron.data.MaterialData;
import iron.math.Vec4;
import iron.object.Object;

/**
	A scene's compositor plan, read from its settings file. The export
	(blender/arm/viewport/compositor.py build()) has already resolved every target name.
**/
typedef TCompositor = {
	var steps: Array<TCompositorStep>;
	/** The render passes the stages read (image, transparent, depth, aov<i>). The renderer draws only these. **/
	var passes: Array<String>;
	/** The target of the last stage. **/
	var result: String;
}

/** One step: a stage (kind "stage") or a Glare node (kind "glare"). Only the fields of its kind are set. **/
typedef TCompositorStep = {
	var kind: String;
	// Stage: a shader drawn into `target`. It reads render passes by name, and the
	// targets of earlier steps as [sampler, target] pairs.
	@:optional var shader: String;
	@:optional var target: String;
	@:optional var passes: Array<String>;
	@:optional var targets: Array<Array<String>>;
	// Glare (compositor.py glare_settings()): the node's settings, its highlights
	// target and its glare target (`output`). `input` is "image" or a stage's target.
	@:optional var glare: String;
	@:optional var index: Int;
	@:optional var input: String;
	@:optional var highlights: String;
	@:optional var output: String;
	@:optional var quality: Int;
	@:optional var threshold: Float;
	@:optional var smoothness: Float;
	@:optional var maximum: Float;
	@:optional var strength: Float;
	@:optional var saturation: Float;
	@:optional var tint: Array<Float>;
	@:optional var render_size: Float;
	@:optional var size: Float;
	@:optional var iterations: Int;
	@:optional var fade: Float;
	@:optional var streaks: Int;
	@:optional var angle: Float;
	@:optional var color_modulation: Float;
	@:optional var diagonal: Bool;
	@:optional var sun_position: Array<Float>;
}

/**
	Draws the active scene's compositor. The renderer runs it after the blended
	materials and before temporal anti-aliasing. The plan is a list of steps in
	drawing order:
	- A stage: a shader generated from the node tree, drawn into its target. It
	  reads the render passes and the targets of earlier steps it uses. The last
	  stage draws into the result.
	- A Glare node: its highlights first, then the passes of its type (Bloom,
	  Streaks, Simple Star, Sun Beams) into its glare target. These are fixed
	  shaders, drawn at the node's Quality (a fraction of the full size).
	All target names are built once per scene in setScene(), so drawing builds no strings.

	It does not depend on a particular renderer. The renderer passes in its image,
	its frame number and the targets of its render passes (draw()), and all
	targets come from ViewportTargets.
**/
class ViewportCompositor {

	static inline var MAX_LEVELS = 12; // Bloom: the highlights and up to 11 blurred levels
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
	// Sun Beams: most samples per pixel along a ray. Longer rays use this many,
	// with a start jittered per pixel and frame.
	static inline var SUN_SAMPLES = 64;
	// Simple Star's two lines: diagonal, or along the axes
	static var DIAGONAL_LINES = [[1.0, 1.0], [1.0, -1.0]];
	static var AXIS_LINES = [[1.0, 0.0], [0.0, 1.0]];

	// Uniforms of the Glare pass being drawn (linked to the shaders in register())
	public static var glare0 = new Vec4(); // threshold, smoothness, maximum (negative: no clamp), quality factor
	public static var glare1 = new Vec4(); // strength, saturation, scale (Bloom: 1 / levels), level count (Bloom only)
	public static var glare2 = new Vec4(); // depends on the type (see Shaders/viewport_glare_streak, _star, _sun)
	public static var glare3 = new Vec4();
	public static var glareTint = new Vec4(1, 1, 1, 1);

	static var plan: TCompositor = null;
	static var steps: Array<TCompositorStep> = [];
	static var stageShaders: Array<String> = []; // per step: the stage's shader handle, null for a Glare
	static var glareNames: Array<GlareNames> = []; // per step: a Glare's working targets, null for a stage
	static var frame = 0; // the frame number for Sun Beams' noise, given by the renderer
	static var registered = false;

	public static var active(get, never): Bool;
	static inline function get_active(): Bool return steps.length > 0;

	/** Registers the Glare passes' uniform links with Iron. Called once, from the renderer's init(). **/
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

	/** Whether the active scene's stages read render pass `name` (image, transparent, depth, aov<i>). **/
	public static function reads(name: String): Bool {
		return plan != null && plan.passes.indexOf(name) >= 0;
	}

	/**
		Switches to a scene's plan (null for no compositor). Loads the stages'
		shaders and makes their targets. Called on every scene switch.
	**/
	public static function setScene(path: RenderPath, raw: TCompositor) {
		plan = raw;
		steps = raw != null ? raw.steps : [];
		stageShaders = [];
		glareNames = [];
		for (step in steps) {
			if (step.kind == "stage") {
				var handle = step.shader + "/" + step.shader + "/" + step.shader;
				path.loadShader(handle);
				stageShaders.push(handle);
				glareNames.push(null);
				ViewportTargets.ensure(step.target, 1.0);
			}
			else {
				stageShaders.push(null);
				glareNames.push(new GlareNames(step.output));
				var factor = 1.0 / step.quality;
				ViewportTargets.ensure(step.highlights, factor);
				ViewportTargets.ensure(step.output, factor);
			}
		}
		if (steps.length > 0) {
			for (pass in [PREFILTER, FIREFLY, DOWN, UP, BLOOM, STREAK, STREAK_ADD, STAR, STAR_ADD, SUN, FINISH]) path.loadShader(pass);
		}
	}

	/**
		Draws every step and returns the target that holds the result. `image` is
		the target with the render. `passTargets` gives the target of every other
		render pass the stages read (TCompositor.passes). `frameNumber` seeds Sun
		Beams' noise.
	**/
	public static function draw(path: RenderPath, image: String, frameNumber: Int, passTargets: Map<String, String>): String {
		frame = frameNumber;
		for (s in 0...steps.length) {
			var step = steps[s];
			if (stageShaders[s] != null) {
				ViewportTargets.setAlone(path, step.target);
				for (pass in step.passes) path.bindTarget(pass == "image" ? image : passTargets.get(pass), pass);
				for (read in step.targets) path.bindTarget(read[1], read[0]);
				path.drawShader(stageShaders[s]);
			}
			else {
				drawGlare(path, step, glareNames[s], image);
			}
		}
		return plan.result;
	}

	/** Draws a Glare node: its highlights at the node's Quality, then its type's passes into its glare target. **/
	static function drawGlare(path: RenderPath, step: TCompositorStep, names: GlareNames, image: String) {
		var input = step.input == "image" ? image : step.input;
		glare0.set(step.threshold, step.smoothness, step.maximum, step.quality);
		glareTint.set(step.tint[0], step.tint[1], step.tint[2], 1.0);

		ViewportTargets.setAlone(path, step.highlights);
		path.bindTarget(input, "tex");
		path.drawShader(PREFILTER);

		switch (step.glare) {
			case "bloom": drawBloom(path, step, names);
			case "streaks": drawStreaks(path, step, names);
			case "simple_star": drawStar(path, step, names);
			case "sun_beams": drawSunBeams(path, step);
		}
	}

	/**
		Pixels of the glare image per pixel of Blender's render. Streaks and Simple
		Star step in pixels, so their steps are scaled by this. The glare then keeps
		its look at any window size.
	**/
	static function pixelScale(path: RenderPath, step: TCompositorStep): Float {
		var image = path.renderTargets.get(step.highlights).image;
		var blender: Float = step.render_size / step.quality;
		return blender > 0 ? Math.min(image.width, image.height) / blender : 1.0;
	}

	/** Writes the glare target of Streaks or Simple Star: `sum` times `scale`, then Saturation, Tint and Strength. **/
	static function finish(path: RenderPath, step: TCompositorStep, sum: String, scale: Float) {
		glare1.set(step.strength, step.saturation, scale, 0);
		ViewportTargets.setAlone(path, step.output);
		path.bindTarget(sum, "tex");
		path.drawShader(FINISH);
	}

	/** Returns three targets at the highlights' size: two to alternate between, and the sum (cleared here). **/
	static function summingTargets(path: RenderPath, step: TCompositorStep, names: GlareNames): Array<String> {
		for (name in names.temporaries) ViewportTargets.ensure(name, 1.0 / step.quality);
		ViewportTargets.setAlone(path, names.temporaries[2]);
		path.clearTarget(0x00000000);
		return names.temporaries;
	}

	/**
		Streaks: each streak takes `iterations` passes of four taps, with steps of
		1, 4, 16... pixels. The last pass adds the streak to the sum.
	**/
	static function drawStreaks(path: RenderPath, step: TCompositorStep, names: GlareNames) {
		var t = summingTargets(path, step, names);
		var iterations = step.iterations;
		var count = step.streaks;
		var scale = pixelScale(path, step);
		for (s in 0...count) {
			var angle = step.angle + 2 * Math.PI * s / count;
			var source = step.highlights;
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
		finish(path, step, t[2], 1.0 / (8 * iterations));
	}

	/**
		Simple Star: each of the two lines takes `iterations - 1` passes of the star's
		kernel, with steps of 1, 2, 3... pixels. The last pass adds the line to the sum.
	**/
	static function drawStar(path: RenderPath, step: TCompositorStep, names: GlareNames) {
		var t = summingTargets(path, step, names);
		var fade = step.fade;
		var a = fade / 2;
		var q = (2 - fade) * (1 - a) / (1 + a);
		var passes = step.iterations - 1;
		var scale = pixelScale(path, step);
		for (line in (step.diagonal ? DIAGONAL_LINES : AXIS_LINES)) {
			var source = step.highlights;
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
		finish(path, step, t[2], 1.0);
	}

	/**
		Sun Beams: rays towards the sun position, at most Size times the image
		diagonal long. Like Bloom, it applies Saturation, Tint and Strength in the
		same pass.
	**/
	static function drawSunBeams(path: RenderPath, step: TCompositorStep) {
		var image = path.renderTargets.get(step.highlights).image;
		var diagonal = Math.sqrt(image.width * image.width + image.height * image.height);
		glare1.set(step.strength, step.saturation, 1.0, 0);
		glare2.set(step.sun_position[0], step.sun_position[1], step.size * diagonal, frame);
		glare3.set(SUN_SAMPLES, 0, 0, 0);
		ViewportTargets.setAlone(path, step.output);
		path.bindTarget(step.highlights, "tex");
		path.drawShader(SUN);
	}

	/**
		Bloom: blurs the highlights down a chain of half-size levels, then adds them
		back up from the coarsest, and writes the sum into the glare target.
	**/
	static function drawBloom(path: RenderPath, step: TCompositorStep, names: GlareNames) {
		// Level count, the highlights included: floor(log2(size * the highlights' smaller side))
		var image = path.renderTargets.get(step.highlights).image;
		var extent = step.size * Math.min(image.width, image.height);
		var n = 0;
		while (n < MAX_LEVELS && Math.pow(2, n + 1) <= extent) n++;
		if (n < 1) n = 1;
		glare1.set(step.strength, step.saturation, 1.0 / n, n);

		var previous = step.highlights;
		for (k in 1...n) {
			// Made when first needed. The level count keeps every level at 2 pixels or more.
			ViewportTargets.ensure(names.levels[k], 1.0 / (step.quality * (1 << k)));
			ViewportTargets.setAlone(path, names.levels[k]);
			path.bindTarget(previous, "tex");
			path.drawShader(k == 1 ? FIREFLY : DOWN);
			previous = names.levels[k];
		}
		// Back up from the coarsest level: each step adds the next finer level
		var summed = names.levels[n - 1];
		var k = n - 2;
		while (k >= 1) {
			var target = names.ups[k];
			ViewportTargets.ensure(target, 1.0 / (step.quality * (1 << k)));
			ViewportTargets.setAlone(path, target);
			path.bindTarget(summed, "tex");
			path.bindTarget(names.levels[k], "level");
			path.drawShader(UP);
			summed = target;
			k--;
		}
		ViewportTargets.setAlone(path, step.output);
		path.bindTarget(step.highlights, "hl");
		if (n > 1) path.bindTarget(summed, "up");
		path.drawShader(BLOOM);
	}
}

/** The names of a Glare node's working targets, built from its glare target's name once per scene. **/
private class GlareNames {
	public var temporaries: Array<String>; // Streaks, Simple Star: two to alternate between, and the sum
	public var levels: Array<String>; // Bloom: the blurred levels 1 to MAX_LEVELS - 1 (index 0 unused)
	public var ups: Array<String>; // Bloom: the summed levels on the way up

	public function new(output: String) {
		temporaries = [for (k in 0...3) output + "_t" + k];
		levels = [for (k in 0...12) output + "_l" + k];
		ups = [for (k in 0...12) output + "_u" + k];
	}
}
