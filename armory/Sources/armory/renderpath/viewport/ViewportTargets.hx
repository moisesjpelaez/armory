package armory.renderpath.viewport;

import iron.RenderPath;

/**
	The render targets of the Viewport renderers and their compositor, all made here.

	Every target has a size factor: its size relative to the scaled window
	(Resolution %, setScale()). The renderer's own targets are made once at start
	(create()). Targets a scene asks for (AOVs, compositor stages, Glare levels) go
	through ensure(): made the first time, made again when the factor changes (a
	scene's Glare at another Quality), and freed after a scene switch that does not
	ask for them again (beginScene() / endScene()).

	Passes with extra outputs (setTarget(first, [extra...])): Kha's HTML5 backend
	attaches the extra targets to the first target's framebuffer and leaves them
	there. WebGL then refuses any later draw into the first target alone that reads
	one of them (a feedback loop). So the first target of such a pass is one that
	is never drawn alone while the others are read; Direct3D does not mind either way.
**/
class ViewportTargets {

	/**
		Extra outputs of a pass that draws into its target alone: an empty list,
		not none. Kha's HTML5 backend (Graphics.begin) leaves the extra outputs of an
		earlier pass on the same target attached and enabled, and WebGL then refuses
		every draw whose shader writes fewer outputs; an empty list makes it reset
		them. Krom treats an empty list as none. Can go once Kha resets them itself.
	**/
	static var ALONE: Array<String> = [];

	static var path: RenderPath = null;
	static var scale = 1.0;
	static var factors = new Map<String, Float>(); // every target made here
	static var kept = new Map<String, Bool>(); // never freed (see create(), ensure())
	static var used = new Map<String, Bool>(); // asked for since the last beginScene()

	/** Draws into `target` only (every pass of these renderers without extra outputs uses this). **/
	public static inline function setAlone(path: RenderPath, target: String) {
		path.setTarget(target, ALONE);
	}

	/** `windowScale`: Resolution % / 100 of the first scene. **/
	public static function init(renderPath: RenderPath, windowScale: Float) {
		path = renderPath;
		scale = windowScale;
	}

	/** One of the renderer's own targets, drawn by every scene: made now and kept. **/
	public static function create(name: String, depthBuffer: String = null, factor = 1.0) {
		kept.set(name, true);
		make(name, factor, depthBuffer);
	}

	/**
		A target the active scene draws, `factor` times the scaled window: made the
		first time, made again when its factor changed. Targets sharing another
		target's depth buffer are kept once made: freeing one in Kha's HTML5 backend
		(Image.unload) would delete the depth buffer it borrows.
	**/
	public static function ensure(name: String, factor = 1.0, depthBuffer: String = null) {
		used.set(name, true);
		var current = factors.get(name);
		if (current == factor) return;
		if (current != null) {
			if (depthBuffer != null) throw 'Viewport renderer: target $name shares a depth buffer and cannot change size';
			free(name);
		}
		if (depthBuffer != null) kept.set(name, true);
		make(name, factor, depthBuffer);
	}

	/** A scene switch starts: the targets it does not ask for again (ensure()) are freed by endScene(). **/
	public static function beginScene() {
		used.clear();
	}

	/**
		The new scene has asked for its targets: the others go. Targets made later,
		while drawing (Bloom levels, which depend on the window), are asked for again
		every frame they are drawn, so they stay until a scene stops drawing them.
	**/
	public static function endScene() {
		for (name in [for (name in factors.keys()) name]) {
			if (!used.exists(name) && !kept.exists(name)) free(name);
		}
	}

	/** Resolution % / 100 of the active scene: every target follows. **/
	public static function setScale(windowScale: Float) {
		if (windowScale == scale) return;
		scale = windowScale;
		for (name => factor in factors) path.renderTargets.get(name).raw.scale = scale * factor;
		path.resize();
	}

	static function make(name: String, factor: Float, depthBuffer: String) {
		var t = new RenderTargetRaw();
		t.name = name;
		t.width = 0;
		t.height = 0;
		t.format = "RGBA64";
		t.scale = scale * factor;
		t.depth_buffer = depthBuffer;
		path.createRenderTarget(t);
		factors.set(name, factor);
	}

	static function free(name: String) {
		var target = path.renderTargets.get(name);
		if (target != null && target.image != null) target.image.unload();
		path.renderTargets.remove(name);
		factors.remove(name);
	}
}
