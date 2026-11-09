// Shadow pass of the Viewport renderer: each pixel's visibility from up to 4
// shadow-casting lights, one channel each (LightData.shadowChannel, set by RasterLights),
// with the lighting pass's own shadow code: arm_shadow() for the light direction and
// reach arm_light() uses (vpraster_lights.glsl, put before this file by lighting.py).
// The lighting pass then reads the result (ARM_SHADOWS_FROM_PASS) instead of running
// that code, whose mere presence made the whole lighting shader slower.

in vec2 texCoord;
uniform sampler2D gbuffer1;
uniform sampler2D gbufferDepth;
uniform mat4 invVP;

out vec4 fragColor;

void main()
{
    float depth = textureLod(gbufferDepth, texCoord, 0.0).r;
    if (depth == 1.0) discard; // sky: the lighting pass skips it too
    vec4 g1 = textureLod(gbuffer1, texCoord, 0.0);

    // As the lighting pass (vpraster_lighting.glsl)
    vec2 ndc = texCoord * 2.0 - 1.0;
#ifdef _InvY
    ndc.y = -ndc.y;
#endif
    vec4 world = invVP * vec4(ndc, depth * 2.0 - 1.0, 1.0);
    vec3 P = world.xyz / world.w;
    vec3 geomNormal = arm_decode_octahedral(g1.zw); // the triangle's own normal

    vec4 visibility = vec4(1.0);
    int lights = min(u_numActiveLightSources, MAX_LIGHT_SOURCES);
    for (int i = 0; i < lights; i++)
    {
        LightData light = arm_get_light(i);
        if (light.shadowChannel < 0.0) continue;
        float v = 1.0;
        if (light.kind == ARM_LIGHT_SUN)
        {
            v = arm_shadow(light, P, geomNormal, -light.direction);
        }
        else
        {
            // Only where the light reaches: arm_light() skips the shadow elsewhere
            vec3 toLight = light.position - P;
            float distanceSq = max(dot(toLight, toLight), 1e-8);
            vec3 direction = toLight * inversesqrt(distanceSq);
            if (arm_light_reach(light, P, direction, distanceSq) > 0.0) v = arm_shadow(light, P, geomNormal, direction);
        }
        int slot = int(light.shadowChannel);
        if (slot == 0) visibility.x = v;
        else if (slot == 1) visibility.y = v;
        else if (slot == 2) visibility.z = v;
        else visibility.w = v;
    }
    fragColor = visibility;
}
