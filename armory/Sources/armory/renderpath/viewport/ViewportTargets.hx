package armory.renderpath.viewport;

import iron.RenderPath;

/**
	Render target helpers shared by the Viewport renderers and their compositor.

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

	/** Draws into `target` only (every pass of these renderers without extra outputs uses this). **/
	public static inline function setAlone(path: RenderPath, target: String) {
		path.setTarget(target, ALONE);
	}
}
