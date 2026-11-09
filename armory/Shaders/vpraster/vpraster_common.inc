// Small helpers shared by the Viewport renderer's shaders: screen motion, per-pixel
// noise and the world image lookup. Shaders use it with #include "vpraster_common.inc";
// the build copies it next to them (see renderpath.py). The lighting pass pastes it
// in at the top instead (see lighting.py).
#ifndef ARM_VPRASTER_COMMON
#define ARM_VPRASTER_COMMON

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795
#endif

// Screen motion of a point in NDC, from its clip position last frame to this frame.
// A point that was behind last frame's camera (w <= 0) has no last position. Dividing
// by w there would flip the motion or make it infinite. The motion then points off
// screen instead, which temporal anti-aliasing reads as "no history".
vec2 arm_motion(vec4 clip, vec4 previous)
{
    if (previous.w <= 0.0) return vec2(4.0);
    return clip.xy / clip.w - previous.xy / previous.w;
}

// Interleaved gradient noise (Jimenez 2014), in [0, 1). The pattern moves every frame,
// so temporal anti-aliasing averages the noise away.
float arm_ign(vec2 pixel, float frame)
{
    vec2 p = pixel + 5.588238 * frame;
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Texture coordinates of a direction in the world image (a latitude-longitude map).
// The direction must already be in the image's frame (u_envMatrix, see RasterUniforms).
vec2 arm_latlong(vec3 d)
{
    return vec2(atan(d.x, -d.z) / M_PI * 0.5 + 0.5, -asin(clamp(d.y, -1.0, 1.0)) / M_PI + 0.5);
}

#endif
