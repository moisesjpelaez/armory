package armory.logicnode;

class GetWorldNode extends LogicNode {

	public function new(tree: LogicTree) {
		super(tree);
	}

	override function get(from: Int): Dynamic {
		return iron.Scene.active.raw.world_ref;
	}
}
