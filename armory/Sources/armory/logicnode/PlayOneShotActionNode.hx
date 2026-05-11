package armory.logicnode;

import iron.object.Object;

class PlayOneShotActionNode extends LogicNode {

	public function new(tree: LogicTree) {
		super(tree);
	}

	override function run(from: Int) {
		var object: Object = inputs[1].get();
		var action: String = inputs[2].get();
		var blendTime: Float = inputs[3].get();
		var speed: Float = inputs[4].get();
		var boneCollection: String = inputs[5].get();

		if (object == null) return;
		var animation = object.animation;
		if (animation == null) animation = object.getParentArmature(object.name);
		if (animation == null) return;

		animation.playOneShot(action, function() {
			runOutput(1);
		}, blendTime, speed, boneCollection);

		runOutput(0);
	}
}
