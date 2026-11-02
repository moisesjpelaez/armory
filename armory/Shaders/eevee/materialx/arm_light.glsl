// Universal Blender light. kind: 0 = sun, 1 = point, 2 = spot, 3 = area.
//   sun:   strength is irradiance in W/m2; direction is where the light travels.
//   point: power in W, radiant intensity P / (4 pi), inverse-square falloff.
//   spot:  a point light masked by a cone; spot_size is the full cone angle,
//          spot_blend softens the edge inwards.
//   area:  power in W from a one-sided flat (Lambertian) emitter facing
//          `direction`: radiant intensity P cos(theta) / pi. Its size is not
//          modelled yet (treated as a small emitter).
// Point, spot and area lights fade out towards `cutoff` (influence radius in
// metres from Eevee's light_threshold or the light's custom distance, 0 = none)
// with the window (1 - (d / cutoff)^4)^2, as measured on Eevee.
void arm_light(LightData light, vec3 position, out lightshader result)
{
    if (light.kind == 0)
    {
        result.direction = -light.direction;
        result.intensity = light.color * light.energy;
        return;
    }

    vec3 toLight = light.position - position;
    float distanceSq = max(dot(toLight, toLight), 1e-8);
    result.direction = toLight * inversesqrt(distanceSq);

    float window = 1.0;
    if (light.cutoff > 0.0)
    {
        float x = distanceSq / (light.cutoff * light.cutoff);
        window = clamp(1.0 - x * x, 0.0, 1.0);
        window *= window;
    }

    if (light.kind == 3)
    {
        float cosEmit = max(dot(-result.direction, light.direction), 0.0);
        result.intensity = light.color * (light.energy * cosEmit * window / (M_PI * distanceSq));
        return;
    }

    result.intensity = light.color * (light.energy * window / (4.0 * M_PI * distanceSq));

    if (light.kind == 2)
    {
        float cosAngle = dot(-result.direction, light.direction);
        float cosEdge = cos(light.spot_size * 0.5);
        float blendWidth = max((1.0 - cosEdge) * light.spot_blend, 1e-6);
        result.intensity *= smoothstep(0.0, 1.0, (cosAngle - cosEdge) / blendWidth);
    }
}
