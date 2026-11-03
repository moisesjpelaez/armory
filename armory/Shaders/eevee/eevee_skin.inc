// Skinning as Blender's Armature modifier deforms (blender/arm/eevee/vertex.py):
// ARM_SKIN_LINEAR blends the bones' matrices (Preserve Volume off, Blender's
// default), ARM_SKIN_DUAL blends dual quaternions (Preserve Volume on). Bones and
// weights come from Armory's mesh data (4 per vertex); the bone data from
// armory.renderpath.eevee.EeveeUniforms. ARM_SKIN_PREVIOUS adds last frame's pose,
// for the screen motion. ARM_MAX_BONES: iron.object.BoneAnimation.skinMaxBones.

#ifdef ARM_SKIN
ivec4 armBones; // set from the `bone` attribute in main()

#ifdef ARM_SKIN_LINEAR
// 3 rows of the bone's matrix per bone
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
// Real and dual part per bone
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

// Dual quaternion skinning (Kavan et al. 2008), blended in the hemisphere of the first bone
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
