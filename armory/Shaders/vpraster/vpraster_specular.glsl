// Eevee's specular reflectance and lamp highlights, measured (materialx-recon):
// used by the lighting pass (vpraster_lighting.glsl) and the lamps (vpraster_lights.glsl).

// Eevee's specular reflectance, measured (Shaders/vpraster/vpraster_dfg.bin, see
// RasterUniforms): a split-sum table, x = scale of F0, y = scale of F90, rows
// N.V = 1 - (i + 0.5) / 32 (row 0 = head-on), columns roughness j / 31.
uniform sampler2D u_armDfg;

vec2 arm_dfg(float NdotV, float alpha)
{
    float roughness = sqrt(clamp(alpha, 0.0, 1.0));
    vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, clamp(1.0 - NdotV, 0.5 / 32.0, 31.5 / 32.0));
    return textureLod(u_armDfg, uv, 0.0).xy;
}

// Lamp reflections, measured on Eevee (Shaders/vpraster/vpraster_ltc.bin): a Linearly
// Transformed Cosine lobe (Heitz et al. 2016) fitted to Eevee's lamp highlights.
// 32 x 64 texels, rows N.V = 1 - i / 31 (row 0 exactly head-on), columns
// roughness j / 31. Top half: inverse matrix [[x, 0, y], [0, z, 0], [w, 0, 1]] in a
// frame with x along the view direction projected on the surface and z along the
// normal; bottom half: the lobe's scale (x). The lobe is not clipped at the
// surface's horizon (measured on Eevee); only the lamp's outline is clipped where
// it dips below the horizon of the lobe's own frame (arm_polygon_cosine).
uniform sampler2D u_armLtc;

// A lamp as seen from the shaded point, filled by arm_light (vpraster_lights.glsl).
// Measured on Eevee: a lamp's highlight is its lobe averaged over the lamp's solid
// angle, so lamps with a size keep their outline here.
#define ARM_LAMP_VERTS 8
struct ArmLamp
{
    vec3 intensity;              // irradiance at normal incidence (W/m2), reach and shadow included
    vec3 direction;              // towards the lamp
    vec3 verts[ARM_LAMP_VERTS];  // outline as unit directions (disc, sphere or area light)
    int count;                   // outline vertices; 0 = too small to matter (a point)
    // Solid angle of the outline: exact for cones (sun, point, spot); a polygon's
    // triple products lose all float precision for small lamps
    float solidAngle;
    // Circular lamps (sun, point, spot): the cone's axis and sin^2 of its half angle (0 = not a cone)
    vec3 coneAxis;
    float coneSinSq;
};

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
    return abs(sum) / (2.0 * M_PI);
}

// Solid angle of the spherical polygon (fan of triangles, Van Oosterom and Strackee)
float arm_polygon_solid_angle(ArmLamp lamp, int n)
{
    float omega = 0.0;
    vec3 a = lamp.verts[0];
    for (int i = 1; i < ARM_LAMP_VERTS - 1; i++)
    {
        if (i + 1 >= n) break;
        vec3 b = lamp.verts[i];
        vec3 c = lamp.verts[i + 1];
        omega += 2.0 * atan(abs(dot(a, cross(b, c))), 1.0 + dot(a, b) + dot(b, c) + dot(c, a));
    }
    return omega;
}

// The shaded point's lamp lobe, the same for every lamp (arm_lobe(), once per pixel):
// the LTC matrix and scale for its roughness and N.V, and the lobe's frame
struct ArmLobe
{
    vec4 m;      // inverse matrix (u_armLtc, top half)
    float scale; // the lobe's scale (bottom half)
    float det;   // determinant of the inverse matrix
    vec3 T1;     // view direction projected on the surface
    vec3 T2;     // N x T1
};

ArmLobe arm_lobe(vec3 N, vec3 V, float NdotV, float alpha)
{
    ArmLobe lobe;
    float roughness = sqrt(clamp(alpha, 0.0, 1.0));
    float row = clamp(1.0 - NdotV, 0.0, 1.0) * 31.0 + 0.5;
    vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, row / 64.0);
    lobe.m = textureLod(u_armLtc, uv, 0.0);
    lobe.scale = textureLod(u_armLtc, uv + vec2(0.0, 0.5), 0.0).x;
    lobe.det = lobe.m.z * (lobe.m.x - lobe.m.y * lobe.m.w);
    vec3 T1 = V - N * dot(N, V);
    lobe.T1 = dot(T1, T1) > 1e-8 ? normalize(T1) : (abs(N.z) < 0.999 ? normalize(cross(N, vec3(0.0, 0.0, 1.0))) : vec3(1.0, 0.0, 0.0));
    lobe.T2 = cross(N, lobe.T1);
    return lobe;
}

// Diffuse from the lamp: the cosine averaged over the lamp's outline, clipped at the
// surface horizon (measured on Eevee: large lamps light diffuse surfaces by their
// visible shape), in place of N.L. The polygon's cosine does not depend on how the
// frame turns about N: it uses the lobe's.
float arm_lamp_cosine(ArmLamp lamp, ArmLobe lobe, vec3 N, float NdotL)
{
    if (lamp.count == 0) return NdotL;
    if (lamp.coneSinSq > 0.0)
    {
        // Circular lamp: closed form of the cosine over a disc of angular radius a cut by
        // the horizon (Snyder 1996), free of the cancellation the polygon edges suffer
        // with small lamps near the horizon
        float cosTheta = clamp(dot(N, lamp.coneAxis), -1.0, 1.0);
        float sinSq = lamp.coneSinSq;
        float projected; // integral of the cosine over the visible disc
        if (cosTheta * cosTheta > sinSq)
            projected = M_PI * sinSq * max(cosTheta, 0.0);
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
        return projected / max(lamp.solidAngle, 1e-12);
    }
    vec3 local[ARM_LAMP_VERTS + 1];
    for (int i = 0; i < ARM_LAMP_VERTS; i++)
    {
        if (i >= lamp.count) break;
        vec3 d = lamp.verts[i];
        local[i] = vec3(dot(d, lobe.T1), dot(d, lobe.T2), dot(d, N));
    }
    float omega = max(lamp.solidAngle, 1e-12);
    return M_PI * arm_polygon_cosine(local, lamp.count) / omega;
}

// f * cos towards the lamp for F = 1: the lobe at L for a small lamp, else the lobe
// averaged over the lamp's polygon
float arm_lamp_lobe(ArmLamp lamp, ArmLobe lobe, vec3 N, vec3 L)
{
    vec4 m = lobe.m;
    if (lamp.count > 0)
    {
        vec3 transformed[ARM_LAMP_VERTS + 1];
        for (int i = 0; i < ARM_LAMP_VERTS; i++)
        {
            if (i >= lamp.count) break;
            vec3 d = lamp.verts[i];
            vec3 l = vec3(dot(d, lobe.T1), dot(d, lobe.T2), dot(d, N));
            transformed[i] = vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
        }
        float omega = max(lamp.solidAngle, 1e-12);
        return lobe.scale * arm_polygon_cosine(transformed, lamp.count) / omega;
    }
    vec3 l = vec3(dot(L, lobe.T1), dot(L, lobe.T2), dot(L, N));
    vec3 lo = vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
    float len2 = dot(lo, lo);
    float len = sqrt(len2);
    return lobe.scale * max(lo.z / len, 0.0) / M_PI * abs(lobe.det) / (len2 * len);
}

