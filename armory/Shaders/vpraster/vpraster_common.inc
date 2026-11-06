// Shared by the Viewport renderer's shaders (#include "vpraster_common.inc"): the build
// copies it next to them in compiled/Shaders (blender/arm/viewport/raster/renderpath.py).
#ifndef ARM_VPRASTER_COMMON
#define ARM_VPRASTER_COMMON

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795
#endif

// Screen motion (NDC) from a point's clip position last frame to this frame's. A
// point that was behind last frame's camera (w <= 0) has no last position: the
// motion then points off screen, which temporal anti-aliasing takes as "no history"
// (a division by w there would flip the motion or make it infinite)
vec2 arm_motion(vec4 clip, vec4 previous)
{
    if (previous.w <= 0.0) return vec2(4.0);
    return clip.xy / clip.w - previous.xy / previous.w;
}

// Interleaved gradient noise (Jimenez 2014) in [0, 1), moved each frame:
// per-pixel noise that temporal anti-aliasing averages
float arm_ign(vec2 pixel, float frame)
{
    vec2 p = pixel + 5.588238 * frame;
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Texture coordinates of a direction in the baked world image (latitude-longitude),
// for a direction already in the image's frame (u_envMatrix, RasterUniforms)
vec2 arm_latlong(vec3 d)
{
    return vec2(atan(d.x, -d.z) / M_PI * 0.5 + 0.5, -asin(clamp(d.y, -1.0, 1.0)) / M_PI + 0.5);
}

#endif
