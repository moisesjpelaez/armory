from arm.logicnode.arm_nodes import *

class VirtualButtonNode(ArmLogicTreeNode):
    """Activates the output on the given virtual button event."""
    bl_idname = 'LNMergedVirtualButtonNode'
    bl_label = 'Virtual Button'
    arm_section = 'virtual'
    arm_version = 1

    property0: EnumProperty(
        items = [('Started', 'Started', 'The virtual button starts to be pressed'),
                 ('Down', 'Down', 'The virtual button is pressed'),
                 ('Released', 'Released', 'The virtual button stops being pressed')],
        name='', default='Down')
    property1: StringProperty(name='', default='button')

    def init(self, context):
        super(VirtualButtonNode, self).init(context)
        self.add_output('ArmNodeSocketAction', 'Out')
        self.add_output('NodeSocketBool', 'State')

    def draw_buttons(self, context, layout):
        layout.prop(self, 'property0')
        layout.prop(self, 'property1')
