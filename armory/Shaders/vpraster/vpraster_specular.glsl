// Specular reflection for the lighting shader, matching Eevee:
// - arm_dfg(): how much light a glossy surface reflects in total (from the DFG table).
// - arm_lobe(), arm_lamp_lobe(): the highlight a lamp makes on a glossy surface.
// - arm_lamp_cosine(): the diffuse light of a lamp with a size.
// lighting.py pastes this file before vpraster_lights.glsl and vpraster_shading.glsl.
// Both tables are textures that RasterUniforms loads from Shaders/vpraster/*.bin.

// DFG table: Eevee's split-sum reflectance, 32 x 32 texels.
// Rows: N.V = 1 - (i + 0.5) / 32 (row 0 is head-on). Columns: roughness j / 31.
// x: the scale of F0 (reflectance head-on). y: the scale of F90 (at grazing angles).
uniform sampler2D u_armDfg;

// The DFG table at N.V and the GGX alpha (alpha = roughness^2)
vec2 arm_dfg(float NdotV, float alpha) {
	float roughness = sqrt(clamp(alpha, 0.0, 1.0));
	vec2 uv = vec2(roughness * (31.0 / 32.0) + 0.5 / 32.0, clamp(1.0 - NdotV, 0.5 / 32.0, 31.5 / 32.0));
	return textureLod(u_armDfg, uv, 0.0).xy;
}

// LTC table: the shape of a lamp's highlight, as a Linearly Transformed Cosine lobe
// (Heitz et al. 2016) fitted to Eevee's lamp highlights. 32 x 64 texels.
// Rows: N.V = 1 - i / 31 (row 0 is exactly head-on). Columns: roughness j / 31.
// Top half: the inverse matrix [[x, 0, y], [0, z, 0], [w, 0, 1]]. Its frame has x
// along the view direction projected on the surface and z along the normal.
// Bottom half: the lobe's scale, in x.
// As in Eevee, the lobe is not cut at the surface's horizon. Only the lamp's outline
// is cut where it dips below the horizon of the lobe's own frame (arm_polygon_cosine).
uniform sampler2D u_armLtc;

// A lamp as seen from the shaded point, filled by arm_light() (vpraster_lights.glsl).
// As in Eevee, a lamp's highlight is the lobe averaged over the lamp's solid angle,
// so a lamp with a size keeps its outline.
#define ARM_LAMP_VERTS 8
struct ArmLamp {
	vec3 intensity;              // irradiance at normal incidence (W/m2), reach and shadow included
	vec3 direction;              // towards the lamp
#ifndef ARM_POINT_LAMPS
	vec3 verts[ARM_LAMP_VERTS];  // outline as unit directions (disc, sphere or area light)
#endif
	int count;                 // outline vertices; 0 = too small to matter (a point)
	// Solid angle of the outline. Exact for cones (sun, point, spot), because a
	// polygon's triple products lose all float precision for small lamps.
	float solidAngle;
	// Circular lamps (sun, point, spot): the cone's axis and sin^2 of its half angle (0 = not a cone)
	vec3 coneAxis;
	float coneSinSq;
};

// ARM_POINT_LAMPS treats every lamp as a point (count 0) and leaves out the outline
// code. It leaves out code this frame doesn't need, because unused code still slows
// the shader down. lighting.py's docstring lists the shader's versions.
#ifndef ARM_POINT_LAMPS
// Integral of the clamped cosine / pi over the spherical polygon v0..v(n-1), cut to
// z >= 0. Edge integral of Heitz et al. 2016, in a form that stays precise.
float arm_polygon_cosine(vec3 v[ARM_LAMP_VERTS + 1], int n) {
	// Cut the polygon at z = 0 (Sutherland-Hodgman clipping against one plane)
	vec3 c[ARM_LAMP_VERTS + 2];
	int m = 0;
	for (int i = 0; i < ARM_LAMP_VERTS + 1; i++) {
		if (i >= n) break;
		vec3 a = v[i];
		vec3 b = v[i + 1 < n ? i + 1 : 0];
		if (a.z >= 0.0) c[m++] = a;
		if ((a.z >= 0.0) != (b.z >= 0.0)) c[m++] = mix(a, b, a.z / (a.z - b.z));
	}
	float sum = 0.0;
	for (int i = 0; i < ARM_LAMP_VERTS + 2; i++) {
		if (i >= m) break;
		vec3 a = normalize(c[i]);
		vec3 b = normalize(c[i + 1 < m ? i + 1 : 0]);
		vec3 x = cross(a, b);
		float s = length(x);
		float angle = 2.0 * asin(clamp(0.5 * length(a - b), 0.0, 1.0)); // precise for short edges, unlike acos(dot(a, b))
		sum += s > 1e-12 ? x.z * angle / s : 0.0;
	}
	return abs(sum) / (2.0 * M_PI);
}

// Solid angle of the lamp's outline with n vertices: a fan of triangles, each by the
// formula of Van Oosterom and Strackee 1983
float arm_polygon_solid_angle(ArmLamp lamp, int n) {
	float omega = 0.0;
	vec3 a = lamp.verts[0];
	for (int i = 1; i < ARM_LAMP_VERTS - 1; i++) {
		if (i + 1 >= n) break;
		vec3 b = lamp.verts[i];
		vec3 c = lamp.verts[i + 1];
		omega += 2.0 * atan(abs(dot(a, cross(b, c))), 1.0 + dot(a, b) + dot(b, c) + dot(c, a));
	}
	return omega;
}
#endif

// The highlight lobe of the shaded point: the LTC matrix and scale for its roughness
// and N.V, and the lobe's frame. It is the same for every lamp, so arm_lobe()
// computes it once per pixel.
struct ArmLobe {
	vec4 m;      // inverse matrix (u_armLtc, top half)
	float scale; // the lobe's scale (bottom half)
	float det;   // determinant of the inverse matrix
	vec3 T1;     // view direction projected on the surface
	vec3 T2;     // N x T1
};

// The lobe from the LTC table. Seen head-on, the view direction has no projection on
// the surface, so any direction across N serves as T1.
ArmLobe arm_lobe(vec3 N, vec3 V, float NdotV, float alpha) {
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

// Direction `d` in the lobe's frame: x along T1, y along T2, z along the normal N
vec3 arm_lobe_frame(ArmLobe lobe, vec3 N, vec3 d) {
	return vec3(dot(d, lobe.T1), dot(d, lobe.T2), dot(d, N));
}

// Direction `l` (in the lobe's frame) times the lobe's inverse LTC matrix `m`. The
// matrix is stored as 4 values, laid out as u_armLtc's comment lists.
vec3 arm_ltc_transform(vec4 m, vec3 l) {
	return vec3(m.x * l.x + m.y * l.z, m.z * l.y, m.w * l.x + l.z);
}

// Diffuse light from a lamp: replaces N.L by the cosine averaged over the lamp's
// outline, cut at the surface's horizon. As in Eevee, a large lamp lights a diffuse
// surface by its visible shape. Any frame around N gives the same result, so this
// reuses the lobe's frame.
float arm_lamp_cosine(ArmLamp lamp, ArmLobe lobe, vec3 N, float NdotL) {
#ifdef ARM_POINT_LAMPS
	return NdotL;
#else
	if (lamp.count == 0) return NdotL;
	if (lamp.coneSinSq > 0.0) {
		// Circular lamp: closed form of the cosine over a disc cut by the horizon
		// (Snyder 1996). It stays precise for small lamps near the horizon, where the
		// polygon's edge terms cancel out.
		float cosTheta = clamp(dot(N, lamp.coneAxis), -1.0, 1.0);
		float sinSq = lamp.coneSinSq;
		float projected; // integral of the cosine over the visible disc
		if (cosTheta * cosTheta > sinSq)
			projected = M_PI * sinSq * max(cosTheta, 0.0);
		else {
			float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 1e-8));
			float x = sqrt(max(1.0 / sinSq - 1.0, 1e-8));
			float y = clamp(-x * cosTheta / sinTheta, -1.0, 1.0);
			float s = sinTheta * sqrt(1.0 - y * y);
			projected = max((cosTheta * acos(y) - x * s) * sinSq + atan(s / x), 0.0);
		}
		// Divided by the solid angle, because the lamp's intensity is radiance x solid
		// angle. The product then is exactly radiance x the projected integral.
		return projected / max(lamp.solidAngle, 1e-12);
	}
	vec3 local[ARM_LAMP_VERTS + 1];
	for (int i = 0; i < ARM_LAMP_VERTS; i++) {
		if (i >= lamp.count) break;
		local[i] = arm_lobe_frame(lobe, N, lamp.verts[i]);
	}
	float omega = max(lamp.solidAngle, 1e-12);
	return M_PI * arm_polygon_cosine(local, lamp.count) / omega;
#endif
}

// The lamp's highlight without Fresnel (BRDF x cosine, for F = 1). A lamp with an
// outline averages the lobe over it; a point lamp takes the lobe at L.
float arm_lamp_lobe(ArmLamp lamp, ArmLobe lobe, vec3 N, vec3 L) {
#ifndef ARM_POINT_LAMPS
	if (lamp.count > 0) {
		vec3 transformed[ARM_LAMP_VERTS + 1];
		for (int i = 0; i < ARM_LAMP_VERTS; i++) {
			if (i >= lamp.count) break;
			transformed[i] = arm_ltc_transform(lobe.m, arm_lobe_frame(lobe, N, lamp.verts[i]));
		}
		float omega = max(lamp.solidAngle, 1e-12);
		return lobe.scale * arm_polygon_cosine(transformed, lamp.count) / omega;
	}
#endif
	vec3 lo = arm_ltc_transform(lobe.m, arm_lobe_frame(lobe, N, L));
	float len2 = dot(lo, lo);
	float len = sqrt(len2);
	return lobe.scale * max(lo.z / len, 0.0) / M_PI * abs(lobe.det) / (len2 * len);
}

