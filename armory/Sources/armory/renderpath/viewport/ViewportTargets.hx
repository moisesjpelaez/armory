package armory.renderpath.viewport;

import iron.RenderPath;

/**
	Makes and frees the render targets of the Viewport renderers and their compositor.

	Each target has a size factor: its size relative to the scaled window
	(Resolution %, see setScale()). The renderer's own targets are made once at
	start with create() and kept. Targets a scene asks for (AOVs, compositor
	stages, Glare levels) go through ensure(). It makes a target the first time,
	and makes it again when its factor changes (a Glare node at another Quality).
	On a scene switch, beginScene() and endScene() free the targets the new scene
	does not ask for.

	KHA-HTML5: a pass with extra outputs (setTarget(first, [extra...])) attaches the
	extra targets to the first target's framebuffer, and Kha's HTML5 backend leaves
	them attached. WebGL then refuses a later draw into the first target alone that
	reads one of them (a feedback loop). So the first target of such a pass must be
	one that is never drawn alone while the others are read. Direct3D does not need
	this rule. It can go once Kha detaches the extra targets itself.
**/
class ViewportTargets {

	/**
		The extra outputs of a pass that draws into one target: an empty list, not null.
		Krom treats an empty list like null.

		KHA-HTML5: Graphics.begin() leaves the extra outputs of an earlier pass on the
		same target attached and enabled. WebGL then refuses every draw whose shader
		writes fewer outputs. An empty list makes Kha reset them. It can go once Kha
		resets them itself.
	**/
	static var ALONE: Array<String> = [];

	static var path: RenderPath = null;
	static var scale = 1.0;
	static var factors = new Map<String, Float>(); // every target made here, with its size factor
	static var kept = new Map<String, Bool>(); // never freed (see create() and ensure())
	static var used = new Map<String, Bool>(); // asked for since the last beginScene()

	/** Draws into `target` only. Every pass without extra outputs uses this. **/
	public static inline function setAlone(path: RenderPath, target: String) {
		path.setTarget(target, ALONE);
	}

	/** `windowScale` is the first scene's Resolution % divided by 100. **/
	public static function init(renderPath: RenderPath, windowScale: Float) {
		path = renderPath;
		scale = windowScale;
	}

	/** Makes one of the renderer's own targets, used by every scene. It is never freed. **/
	public static function create(name: String, depthBuffer: String = null, factor = 1.0) {
		kept.set(name, true);
		make(name, factor, depthBuffer);
	}

	/**
		Makes sure a target the active scene draws exists, `factor` times the size of
		the scaled window. Makes it the first time, and again when its factor changes.

		KHA-HTML5: a target that shares another target's depth buffer is never freed.
		Freeing it (Image.unload) would also delete the borrowed depth buffer. It can
		go once Kha's unload leaves a borrowed depth buffer alone.
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

	/**
		Called when a scene switch starts. The new scene then asks for its targets
		with ensure(), and endScene() frees the rest.
	**/
	public static function beginScene() {
		used.clear();
	}

	/**
		Called once the new scene has asked for its targets. Frees the targets it did
		not ask for. Targets made while drawing (Bloom levels, which depend on the
		window size) are asked for again every frame they are drawn. So they stay
		until a scene stops drawing them.
	**/
	public static function endScene() {
		for (name in [for (name in factors.keys()) name]) {
			if (!used.exists(name) && !kept.exists(name)) free(name);
		}
	}

	/** Sets the active scene's Resolution % divided by 100, and resizes every target to match. **/
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
