// Eevee's specular reflectance and lamp highlights, measured (materialx-recon):
// used by the lighting pass (eevee_lighting.glsl) and the lamps (eevee_lights.glsl).

// Eevee's specular reflectance, measured (Shaders/eevee/eevee_dfg.bin, see
// EeveeUniforms): a split-sum table, x = scale of F0, y = scale of F90, rows
// N.V = 1 - (i + 0.5) / 32 (row 0 = head-on), columns roughness j / 31.
uniform sampler2D u_armDfg;

vec2 arm_dfg(float NdotV, float alpha)
{
    float roughness = sqrt(clamp(alpha, 0.0, 1.0));
    vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, clamp(1.0 - NdotV, 0.5 / 32.0, 31.5 / 32.0));
    return textureLod(u_armDfg, uv, 0.0).xy;
}

// Lamp reflections, measured on Eevee (Shaders/eevee/eevee_ltc.bin): a Linearly
// Transformed Cosine lobe (Heitz et al. 2016) fitted to Eevee's lamp highlights.
// 32 x 64 texels, rows N.V = 1 - i / 31 (row 0 exactly head-on), columns
// roughness j / 31. Top half: inverse matrix [[x, 0, y], [0, z, 0], [w, 0, 1]] in a
// frame with x along the view direction projected on the surface and z along the
// normal; bottom half: the lobe's scale (x). Eevee does not clip the lobe at the
// surface horizon.
uniform sampler2D u_armLtc;

// The lamp being shaded as seen from the shaded point (set by arm_light): a
// polygon of unit directions (disc, sphere or area outline), or no vertices for
// a lamp too small to matter. Measured on Eevee: a lamp's highlight is its lobe
// averaged over the lamp's solid angle.
#define ARM_LAMP_VERTS 8
vec3 arm_lampVerts[ARM_LAMP_VERTS];
int arm_lampCount = 0;
// Solid angle of the lamp's outline: exact for cones (sun, point, spot); a polygon's
// triple products lose all float precision for small lamps
float arm_lampSolidAngle = 0.0;
// Circular lamps (sun, point, spot): the cone's axis and sin^2 of its half angle (0 = not a cone)
vec3 arm_lampConeAxis;
float arm_lampConeSinSq = 0.0;

// Integral of the clamped cosine / pi over the spherical polygon v0..v(n-1),
// clipped to z >= 0 (Heitz et al. 2016, edge integral in a stable form).
float arm_polygon_cosine(vec3 v[ARM_LAMP_VERTS + 1], int n)
{
    // Clip against z = 0 (Sutherland-Hodgman, one plane)
    vec3 c[ARM_LAMP_VERTS + 2];
    int m = 0;
    for (int i = 0; i < ARM_LAMP_VERTS + 1; i++)
    {
        if (i >= n) break;
        vec3 a = v[i];
        vec3 b = v[i + 1 < n ? i + 1 : 0];
        if (a.z >= 0.0) c[m++] = a;
        if ((a.z >= 0.0) != (b.z >= 0.0)) c[m++] = mix(a, b, a.z / (a.z - b.z));
    }
    float sum = 0.0;
    for (int i = 0; i < ARM_LAMP_VERTS + 2; i++)
    {
        if (i >= m) break;
        vec3 a = normalize(c[i]);
        vec3 b = normalize(c[i + 1 < m ? i + 1 : 0]);
        vec3 x = cross(a, b);
        float s = length(x);
        float angle = 2.0 * asin(clamp(0.5 * length(a - b), 0.0, 1.0)); // precise for small edges
        sum += s > 1e-12 ? x.z * angle / s : 0.0;
    }
    return abs(sum) / (2.0 * 3.14159265);
}

// Solid angle of the spherical polygon (fan of triangles, Van Oosterom and Strackee)
float arm_polygon_solid_angle(int n)
{
    float omega = 0.0;
    vec3 a = arm_lampVerts[0];
    for (int i = 1; i < ARM_LAMP_VERTS - 1; i++)
    {
        if (i + 1 >= n) break;
        vec3 b = arm_lampVerts[i];
        vec3 c = arm_lampVerts[i + 1];
        omega += 2.0 * atan(abs(dot(a, cross(b, c))), 1.0 + dot(a, b) + dot(b, c) + dot(c, a));
    }
    return omega;
}

// Diffuse from the lamp: the cosine averaged over the lamp's outline, clipped at the
// surface horizon (measured on Eevee: large lamps light diffuse surfaces by their
// visible shape), in place of N.L
float arm_lamp_cosine(vec3 N, float NdotL)
{
    if (arm_lampCount == 0) return NdotL;
    if (arm_lampConeSinSq > 0.0)
    {
        // Circular lamp: closed form of the cosine over a disc of angular radius a cut by
        // the horizon (Snyder 1996), free of the cancellation the polygon edges suffer
        // with small lamps near the horizon
        float cosTheta = clamp(dot(N, arm_lampConeAxis), -1.0, 1.0);
        float sinSq = arm_lampConeSinSq;
        float projected; // integral of the cosine over the visible disc
        if (cosTheta * cosTheta > sinSq)
            projected = 3.14159265 * sinSq * max(cosTheta, 0.0);
        else
        {
            float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 1e-8));
            float x = sqrt(max(1.0 / sinSq - 1.0, 1e-8));
            float y = clamp(-x * cosTheta / sinTheta, -1.0, 1.0);
            float s = sinTheta * sqrt(1.0 - y * y);
            projected = max((cosTheta * acos(y) - x * s) * sinSq + atan(s / x), 0.0);
        }
        // Over the same solid angle the lamp's intensity uses (radiance x solid angle),
        // so the product is radiance x the projected integral, exactly
        return projected / max(arm_lampSolidAngle, 1e-12);
    }
    vec3 T = abs(N.z) < 0.999 ? normalize(cross(N, vec3(0.0, 0.0, 1.0))) : vec3(1.0, 0.0, 0.0);
    vec3 B = cross(N, T);
    vec3 local[ARM_LAMP_VERTS + 1];
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        if (i >= arm_lampCount) break;
        vec3 d = arm_lampVerts[i];
        local[i] = vec3(dot(d, T), dot(d, B), dot(d, N));
    }
    float omega = max(arm_lampSolidAngle, 1e-12);
    return 3.14159265 * arm_polygon_cosine(local, arm_lampCount) / omega;
}

// f * cos towards the lamp for F = 1: the lobe at L for a small lamp, else the lobe
// averaged over the lamp's polygon
float arm_lamp_lobe(vec3 N, vec3 V, vec3 L, float NdotV, float alpha)
{
    float roughness = sqrt(clamp(alpha, 0.0, 1.0));
    float row = clamp(1.0 - NdotV, 0.0, 1.0) * 31.0 + 0.5;
    vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, row / 64.0);
    vec4 m = textureLod(u_armLtc, uv, 0.0);
    float scale = textureLod(u_armLtc, uv + vec2(0.0, 0.5), 0.0).x;
    vec3 T1 = V - N * dot(N, V);
    T1 = dot(T1, T1) > 1e-8 ? normalize(T1) : (abs(N.z) < 0.999 ? normalize(cross(N, vec3(0.0, 0.0, 1.0))) : vec3(1.0, 0.0, 0.0));
    vec3 T2 = cross(N, T1);
    if (arm_lampCount > 0)
    {
        vec3 transformed[ARM_LAMP_VERTS + 1];
        for (int i = 0; i < ARM_LAMP_VERTS; i++)
        {
            if (i >= arm_lampCount) break;
            vec3 d = arm_lampVerts[i];
            vec3 l = vec3(dot(d, T1), dot(d, T2), dot(d, N));
            transformed[i] = vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
        }
        float omega = max(arm_lampSolidAngle, 1e-12);
        return scale * arm_polygon_cosine(transformed, arm_lampCount) / omega;
    }
    vec3 l = vec3(dot(L, T1), dot(L, T2), dot(L, N));
    vec3 lo = vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
    float len2 = dot(lo, lo);
    float len = sqrt(len2);
    float det = m.z * (m.x - m.y * m.w);
    return scale * max(lo.z / len, 0.0) / 3.14159265 * abs(det) / (len2 * len);
}

