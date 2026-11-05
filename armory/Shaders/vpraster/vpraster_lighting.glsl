// Lighting pass of the Viewport renderer: lights every pixel of the material images
// (materialx/arm_gbuffer.glsl) with arm_shade() (vpraster_shading.glsl, put before
// this file by lighting.py together with vpraster_specular.glsl and vpraster_lights.glsl).

in vec2 texCoord;
uniform sampler2D gbuffer0;
uniform sampler2D gbuffer1;
uniform sampler2D gbuffer2;
uniform sampler2D gbuffer3;
uniform sampler2D gbuffer4;
uniform sampler2D gbufferDepth;
uniform mat4 invVP;

out vec4 fragColor;

void main()
{
    float depth = textureLod(gbufferDepth, texCoord, 0.0).r;
    if (depth == 1.0) discard; // sky: the world pass drew it
    vec4 g0 = textureLod(gbuffer0, texCoord, 0.0);
    vec4 g1 = textureLod(gbuffer1, texCoord, 0.0);
    vec4 g2 = textureLod(gbuffer2, texCoord, 0.0);
    vec4 g3 = textureLod(gbuffer3, texCoord, 0.0);
    vec4 g4 = textureLod(gbuffer4, texCoord, 0.0);

    vec2 ndc = texCoord * 2.0 - 1.0;
#ifdef _InvY
    ndc.y = -ndc.y;
#endif
    vec4 world = invVP * vec4(ndc, depth * 2.0 - 1.0, 1.0);
    vec3 P = world.xyz / world.w;
    fragColor = vec4(arm_shade(g0, g1, g2, g3, g4.z, P), 1.0);
}
