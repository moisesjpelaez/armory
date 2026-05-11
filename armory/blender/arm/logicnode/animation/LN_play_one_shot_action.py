from arm.logicnode.arm_nodes import *


class PlayOneShotActionNode(ArmLogicTreeNode):
    """
    Plays an animation action as a one-shot over the given Bone Collection mask.

    @input In: Activates the node logic.
    @input Object: States object/armature to run the animation action on.
    @input Action: States animation action to be played as a one-shot.
    @input Blend: Reserved for one-shot blend time.
    @input Speed: Sets rate the animation plays at.
    @input Loop: Sets whether the one-shot should rewind itself after finishing.
    @input Bone Collection: Limits the one-shot to bones in this Blender Bone Collection. Leave empty to affect all bones.

    @output Out: Executes whenever the node is run.
    @output Done: Executes whenever the one-shot animation is finished.
    """
    bl_idname = 'LNPlayOneShotActionNode'
    bl_label = 'Play One Shot Action'
    arm_version = 1

    def arm_init(self, context):
        self.add_input('ArmNodeSocketAction', 'In')
        self.add_input('ArmNodeSocketObject', 'Object')
        self.add_input('ArmNodeSocketAnimAction', 'Action')
        self.add_input('ArmFloatSocket', 'Blend', default_value=0.0)
        self.add_input('ArmFloatSocket', 'Speed', default_value=1.0)
        self.add_input('ArmStringSocket', 'Bone Collection')

        self.add_output('ArmNodeSocketAction', 'Out')
        self.add_output('ArmNodeSocketAction', 'Done')
