"""Material export for the Eevee renderer (called from material/make.py parse()).

Step 1: every material draws with one fixed shader ("eevee_clay"); the
MaterialX pipeline replaces it.
"""
import os
import shutil

import bpy

import arm.assets as assets
import arm.utils

if arm.is_reload(__name__):
    assets = arm.reload_module(assets)
    arm.utils = arm.reload_module(arm.utils)
else:
    arm.enable_reload(__name__)

SHADER_DATA_NAME = 'eevee_clay'

# Mesh vertex data as the exporter writes it: (pos.xyz, nor.z), (nor.xy)
VERTEX_ELEMENTS = [
    {'name': 'pos', 'data': 'short4norm'},
    {'name': 'nor', 'data': 'short2norm'},
]


def parse(material, mat_data, mat_users, mat_armusers):
    """Same contract as material/make.py parse(): returns (sd, rpasses, needs_sss)."""
    shader_data = write_shader_data()

    mat_data['contexts'].append({
        'name': 'mesh',
        'bind_constants': [],
        'bind_textures': [],
        'depth_read': False,
    })

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        mat_data['shader'] = SHADER_DATA_NAME
    else:
        ext = '' if wrd.arm_minimize else '.json'
        mat_data['shader'] = SHADER_DATA_NAME + ext + '/' + SHADER_DATA_NAME

    return shader_data, ['mesh'], False


def write_shader_data():
    """Copies the fixed shader sources into the build and writes their shader data."""
    build_shaders = os.path.join(arm.utils.get_fp_build(), 'compiled', 'Shaders')
    os.makedirs(build_shaders, exist_ok=True)
    sources = os.path.join(arm.utils.get_sdk_path(), 'armory', 'Shaders', 'eevee')
    for ext in ('vert', 'frag'):
        shutil.copy(os.path.join(sources, SHADER_DATA_NAME + '.' + ext + '.glsl'), build_shaders)

    context = {
        'name': 'mesh',
        'depth_write': True,
        'compare_mode': 'less',
        'cull_mode': 'clockwise',
        'vertex_elements': VERTEX_ELEMENTS,
        'color_attachments': ['RGBA64'],
        'vertex_shader': SHADER_DATA_NAME + '.vert',
        'fragment_shader': SHADER_DATA_NAME + '.frag',
        # Not last: Iron's ArmPack reader peeks one byte past an array's length,
        # so an empty array at the very end of the file is read as null.
        'texture_units': [],
        'constants': [
            {'name': 'W', 'type': 'mat4', 'link': '_worldMatrix'},
            {'name': 'N', 'type': 'mat3', 'link': '_normalMatrix'},
            {'name': 'VP', 'type': 'mat4', 'link': '_viewProjectionMatrix'},
        ],
    }
    shader_data = {'name': SHADER_DATA_NAME, 'contexts': [context]}

    wrd = bpy.data.worlds['Arm']
    if wrd.arm_single_data_file:
        from arm import exporter  # imported here: arm.exporter imports this module's caller
        output = exporter.current_output
        output.setdefault('shader_datas', [])
        if not any(sd['name'] == SHADER_DATA_NAME for sd in output['shader_datas']):
            output['shader_datas'].append(shader_data)
    else:
        arm.utils.write_arm(os.path.join(build_shaders, SHADER_DATA_NAME + '.arm'), {'shader_datas': [shader_data]})
        assets.add_shader_data(os.path.join(build_shaders, SHADER_DATA_NAME + '.arm'))

    return shader_data
