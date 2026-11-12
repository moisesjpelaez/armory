package armory.renderpath.viewport.raster;

import kha.arrays.Float32Array;
import iron.math.Mat4;
import iron.object.Object;

/**
	Last frame's world matrix of each mesh and last frame's skin of each skinned
	object, for motion vectors. The renderer calls endFrame() after drawing each
	frame. RasterUniforms gives the remembered values to the shaders.

	Iron's MeshObject.prevMatrix is not used: it changes after every draw call, so
	a mesh drawn twice in a frame (the material pass, then the opaque pass of a
	Blended material) would read this frame's matrix the second time. Every mesh is
	recorded, seen by the camera or not, so one coming back into view moves from
	where it was last frame.
**/
class RasterMotionHistory {

	static var prevWorld = new Map<Object, Mat4>();
	static var meshCount = -1;
	static var meshScene: iron.Scene = null;

	/** The object's world matrix in the last frame. In its first frame, this frame's: no motion. **/
	public static function previousWorld(object: Object): Mat4 {
		if (object == null) return null;
		var prev = prevWorld.get(object);
		return prev != null ? prev : object.transform.worldUnpack;
	}

	/** Called after drawing the frame. Remembers every mesh and skin for the next frame's motion vectors. **/
	public static function endFrame() {
		var scene = iron.Scene.active;
		if (scene == null) return;
		// Forget meshes that left the scene. Checked only when the mesh count or the scene changes.
		if (scene.meshes.length != meshCount || scene != meshScene) {
			meshCount = scene.meshes.length;
			meshScene = scene;
			var kept = new Map<Object, Mat4>();
			for (mesh in scene.meshes) {
				var prev = prevWorld.get(mesh);
				if (prev != null) kept.set(mesh, prev);
			}
			prevWorld = kept;
		}
		for (mesh in scene.meshes) {
			var prev = prevWorld.get(mesh);
			if (prev == null) prevWorld.set(mesh, prev = Mat4.identity());
			prev.setFrom(mesh.transform.worldUnpack);
		}
		#if arm_skin
		endFrameSkins(scene);
		#end
	}

	#if arm_skin
	// Last frame's skin of each skinned object. It is copied after each frame is
	// drawn, so a paused or skipped animation has no motion.
	static var prevMatrices = new Map<iron.object.BoneAnimation, Float32Array>();
	static var prevBones = new Map<iron.object.BoneAnimation, Float32Array>();
	static var animationCount = -1;
	static var animationScene: iron.Scene = null;

	/** The object's skin animation, or null when it has none. **/
	public static inline function skin(object: Object): iron.object.BoneAnimation {
		return object != null ? Std.downcast(object.animation, iron.object.BoneAnimation) : null;
	}

	/**
		The skin's matrices (`matrices` true) or bones (false) in the last frame.
		In its first frame, this frame's: no motion.
	**/
	public static function previousSkin(anim: iron.object.BoneAnimation, matrices: Bool): Float32Array {
		if (anim == null) return null;
		var prev = (matrices ? prevMatrices : prevBones).get(anim);
		return prev != null ? prev : (matrices ? anim.skinMatrices : anim.skinBuffer);
	}

	static function endFrameSkins(scene: iron.Scene) {
		var animations = scene.animations;
		for (a in animations) {
			var anim = Std.downcast(a, iron.object.BoneAnimation);
			if (anim == null || anim.skinBuffer == null) continue;
			copy(prevMatrices, anim, anim.skinMatrices);
			copy(prevBones, anim, anim.skinBuffer);
		}
		// Forget animations that left the scene. Checked only when the animation count
		// or the scene changes, so a swap that keeps the count waits for the next change.
		if (animations.length != animationCount || scene != animationScene) {
			animationCount = animations.length;
			animationScene = scene;
			for (anim in [for (k in prevBones.keys()) k]) {
				if (animations.indexOf(anim) < 0) {
					prevBones.remove(anim);
					prevMatrices.remove(anim);
				}
			}
		}
	}

	static function copy(into: Map<iron.object.BoneAnimation, Float32Array>, anim: iron.object.BoneAnimation, from: Float32Array) {
		var to = into.get(anim);
		if (to == null) into.set(anim, to = new Float32Array(from.length));
		for (i in 0...from.length) to[i] = from[i];
	}
	#end
}
