// Skinning for the material and shadow vertex shaders: deforms a vertex the way
// Blender's Armature modifier does. vertex.py sets the options:
//   ARM_SKIN_LINEAR    blends the bones' matrices (Preserve Volume off, Blender's default)
//   ARM_SKIN_DUAL      blends dual quaternions (Preserve Volume on)
//   ARM_SKIN_PREVIOUS  also has last frame's pose, for the screen motion
// Each vertex has 4 bones and weights from Armory's mesh data. RasterUniforms sets the
// bones' poses. ARM_MAX_BONES is iron.object.BoneAnimation.skinMaxBones.
// arm_skin() returns the skinned position `sp` and normal `sn` (not normalized).

#ifdef ARM_SKIN
ivec4 armBones; // set from the `bone` attribute in main()

#ifdef ARM_SKIN_LINEAR
// 3 rows of each bone's matrix, as vec4s: Direct3D pads each element of a float
// array to 16 bytes
uniform vec4 skinMatrices[ARM_MAX_BONES * 3];
#ifdef ARM_SKIN_PREVIOUS
uniform vec4 skinMatricesPrev[ARM_MAX_BONES * 3];
#endif

vec4 arm_skin_row(int i, bool previous)
{
#ifdef ARM_SKIN_PREVIOUS
    return previous ? skinMatricesPrev[i] : skinMatrices[i];
#else
    return skinMatrices[i];
#endif
}

void arm_skin(vec3 p, vec3 n, bool previous, out vec3 sp, out vec3 sn)
{
    sp = vec3(0.0);
    sn = vec3(0.0);
    for (int k = 0; k < 4; k++)
    {
        int b = armBones[k] * 3;
        vec4 r0 = arm_skin_row(b, previous);
        vec4 r1 = arm_skin_row(b + 1, previous);
        vec4 r2 = arm_skin_row(b + 2, previous);
        sp += weight[k] * vec3(dot(r0, vec4(p, 1.0)), dot(r1, vec4(p, 1.0)), dot(r2, vec4(p, 1.0)));
        sn += weight[k] * vec3(dot(r0.xyz, n), dot(r1.xyz, n), dot(r2.xyz, n));
    }
}
#endif

#ifdef ARM_SKIN_DUAL
// Each bone's dual quaternion: its real part, then its dual part
uniform vec4 skinBones[ARM_MAX_BONES * 2];
#ifdef ARM_SKIN_PREVIOUS
uniform vec4 skinBonesPrev[ARM_MAX_BONES * 2];
#endif

vec4 arm_skin_part(int i, bool previous)
{
#ifdef ARM_SKIN_PREVIOUS
    return previous ? skinBonesPrev[i] : skinBones[i];
#else
    return skinBones[i];
#endif
}

// Dual quaternion skinning (Kavan et al. 2008). Each bone's quaternion is flipped into
// the first bone's hemisphere before blending, so the blend takes the short way round.
void arm_skin(vec3 p, vec3 n, bool previous, out vec3 sp, out vec3 sn)
{
    vec4 first = arm_skin_part(armBones[0] * 2, previous);
    vec4 real = vec4(0.0);
    vec4 dual = vec4(0.0);
    for (int k = 0; k < 4; k++)
    {
        vec4 r = arm_skin_part(armBones[k] * 2, previous);
        float w = dot(r, first) < 0.0 ? -weight[k] : weight[k];
        real += w * r;
        dual += w * arm_skin_part(armBones[k] * 2 + 1, previous);
    }
    float inv = 1.0 / length(real);
    real *= inv;
    dual *= inv;
    sp = p + 2.0 * cross(real.xyz, cross(real.xyz, p) + real.w * p)
           + 2.0 * (real.w * dual.xyz - dual.w * real.xyz + cross(real.xyz, dual.xyz));
    sn = n + 2.0 * cross(real.xyz, cross(real.xyz, n) + real.w * n);
}
#endif
#endif
