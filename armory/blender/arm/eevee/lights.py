"""Light export for the Eevee renderer (called from exporter.export_light()).

The Forward/Deferred export converts strength and spot values for its own
shading; the Eevee renderer reads Blender's values unchanged:
  strength    energy * 2^exposure (sun: W/m2, point/spot/area: W)
  spot_size   full cone angle in radians
  spot_blend  Blender's spot_blend (0..1)
  cutoff_distance  only with "Custom Distance" on (else Eevee's light_threshold applies)
Colour already includes the blackbody temperature (applied by the exporter).
"""
import arm

if arm.is_reload(__name__):
    pass
else:
    arm.enable_reload(__name__)


def export(light, out_light: dict):
    out_light['strength'] = light.energy * pow(2.0, light.exposure)
    if light.type != 'SUN' and light.use_custom_distance:
        out_light['cutoff_distance'] = light.cutoff_distance
    if light.type == 'SPOT':
        out_light['spot_size'] = light.spot_size
        out_light['spot_blend'] = light.spot_blend
