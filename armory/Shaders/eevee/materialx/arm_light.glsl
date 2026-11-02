// Universal Blender light. kind: 0 = sun, 1 = point, 2 = spot.
//   sun:   strength is irradiance in W/m2; direction is where the light travels.
//   point: power in W, radiant intensity P / (4 pi), inverse-square falloff.
//   spot:  a point light masked by a cone; spot_size is the full cone angle,
//          spot_blend softens the edge inwards.
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
    result.intensity = light.color * (light.energy / (4.0 * M_PI * distanceSq));

    if (light.kind == 2)
    {
        float cosAngle = dot(-result.direction, light.direction);
        float cosEdge = cos(light.spot_size * 0.5);
        float blendWidth = max((1.0 - cosEdge) * light.spot_blend, 1e-6);
        result.intensity *= smoothstep(0.0, 1.0, (cosAngle - cosEdge) / blendWidth);
    }
}
