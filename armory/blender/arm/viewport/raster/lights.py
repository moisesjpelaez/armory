"""Light export for the Viewport renderer (called from exporter.export_light()).

The Forward/Deferred export converts strength and spot values for its own
shading; the Viewport renderer reads Blender's values unchanged:
  strength    energy * 2^exposure (sun: W/m2, point/spot/area: W)
  spot_size   full cone angle in radians
  spot_blend  Blender's spot_blend (0..1)
  cutoff_distance  only with "Custom Distance" on (else Eevee's light_threshold applies)
  vpraster_size  [radius, size_x, size_y, shape]: the sun's half angle (radians) or the
              point/spot radius in `radius`; the area light's width and height in
              metres and its shape (0 rectangle, 1 ellipse) in the rest
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
    if light.type == 'SUN':
        out_light['vpraster_size'] = [light.angle * 0.5, 0.0, 0.0, 0.0]
    elif light.type in ('POINT', 'SPOT'):
        out_light['vpraster_size'] = [light.shadow_soft_size, 0.0, 0.0, 0.0]
    else:  # AREA
        square = light.shape in ('SQUARE', 'DISK')
        ellipse = light.shape in ('DISK', 'ELLIPSE')
        out_light['vpraster_size'] = [0.0, light.size, light.size if square else light.size_y, 1.0 if ellipse else 0.0]
