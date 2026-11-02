// Universal Blender light. kind: 0 = sun, 1 = point, 2 = spot, 3 = area.
//   sun:   strength is irradiance in W/m2; direction is where the light travels.
//   point: power in W, radiant intensity P / (4 pi), inverse-square falloff.
//   spot:  a point light masked by a cone; spot_size is the full cone angle,
//          spot_blend softens the edge inwards.
//   area:  power in W from a one-sided flat (Lambertian) emitter facing
//          `direction`: radiant intensity P cos(theta) / pi (diffuse treats it
//          as small; highlights use its outline).
// Point, spot and area lights fade out towards `cutoff` (influence radius in
// metres from Eevee's light_threshold or the light's custom distance, 0 = none)
// with the window (1 - (d / cutoff)^4)^2, as measured on Eevee.
// Shadows: arm_shadow() (glsl_rewrite.SHADOWS) for lights with a shadow view.
// Highlights: the lamp's outline as seen from `position` goes to arm_lampVerts
// (glsl_rewrite.EEVEE_SPECULAR); lamps smaller than the measured table's sun
// (0.29 degree angular radius) are points.

// Cone of half angle `a` around `axis` as a polygon of unit directions
void arm_lamp_cone(vec3 axis, float a)
{
    if (a < 0.005)
    {
        arm_lampCount = 0;
        return;
    }
    vec3 helper = abs(axis.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 x = normalize(cross(helper, axis));
    vec3 y = cross(axis, x);
    float c = cos(a);
    float s = sin(a);
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        float phi = float(i) * (6.28318531 / float(ARM_LAMP_VERTS));
        arm_lampVerts[i] = c * axis + s * (cos(phi) * x + sin(phi) * y);
    }
    arm_lampCount = ARM_LAMP_VERTS;
}

// Rectangle or ellipse of an area light as directions from `position`
void arm_lamp_area(LightData light, vec3 position)
{
    vec3 x = light.tangent * (0.5 * light.size_x);
    vec3 y = cross(light.direction, light.tangent) * (0.5 * light.size_y);
    if (light.shape < 0.5)
    {
        arm_lampVerts[0] = normalize(light.position - x - y - position);
        arm_lampVerts[1] = normalize(light.position + x - y - position);
        arm_lampVerts[2] = normalize(light.position + x + y - position);
        arm_lampVerts[3] = normalize(light.position - x + y - position);
        arm_lampCount = 4;
        return;
    }
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        float phi = float(i) * (6.28318531 / float(ARM_LAMP_VERTS));
        arm_lampVerts[i] = normalize(light.position + cos(phi) * x + sin(phi) * y - position);
    }
    arm_lampCount = ARM_LAMP_VERTS;
}

void arm_light(LightData light, vec3 position, out lightshader result)
{
    if (light.kind == 0)
    {
        result.direction = -light.direction;
        result.intensity = light.color * (light.energy * arm_shadow(light, position, result.direction));
        arm_lamp_cone(result.direction, light.radius);
        return;
    }

    vec3 toLight = light.position - position;
    float distanceSq = max(dot(toLight, toLight), 1e-8);
    result.direction = toLight * inversesqrt(distanceSq);
    if (light.kind == 3)
        arm_lamp_area(light, position);
    else
        arm_lamp_cone(result.direction, asin(clamp(light.radius * inversesqrt(distanceSq), 0.0, 1.0)));

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
