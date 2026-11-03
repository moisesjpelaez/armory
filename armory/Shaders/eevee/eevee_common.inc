// Shared by the Eevee renderer's shaders (#include "eevee_common.inc"): the build
// copies it next to them in compiled/Shaders (blender/arm/eevee/renderpath.py).
#ifndef ARM_EEVEE_COMMON
#define ARM_EEVEE_COMMON

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795
#endif

// Interleaved gradient noise (Jimenez 2014) in [0, 1), moved each frame:
// per-pixel noise that temporal anti-aliasing averages
float arm_ign(vec2 pixel, float frame)
{
    vec2 p = pixel + 5.588238 * frame;
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Texture coordinates of a direction in the baked world image (latitude-longitude),
// for a direction already in the image's frame (u_envMatrix, EeveeUniforms)
vec2 arm_latlong(vec3 d)
{
    return vec2(atan(d.x, -d.z) / M_PI * 0.5 + 0.5, -asin(clamp(d.y, -1.0, 1.0)) / M_PI + 0.5);
}

#endif
