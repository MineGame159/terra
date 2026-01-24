import "utils";

struct BsdfEval {
    float3 value; // The BRDF value (f_r)
    float pdf;    // The probability density of the sampled direction
}

// --- Diffuse Lobe (Cosine Weighted) ---

BsdfEval SampleCosineHemisphere(inout uint state, float3 N) {
    // 1. Get random numbers
    let u1 = Random(state);
    let u2 = Random(state);

    // 2. Concentric Disk Sampling
    let o = 2.0 * float2(u1, u2) - 1.0;
    var r = 0.0;
    var phi = 0.0;

    if (abs(o.x) > 1e-6 || abs(o.y) > 1e-6) {
        if (abs(o.x) > abs(o.y)) {
            r = o.x;
            phi = (float.getPi() / 4.0) * (o.y / o.x);
        } else {
            r = o.y;
            phi = (float.getPi() / 2.0) - (float.getPi() / 4.0) * (o.x / o.y);
        }
    }

    // 3. Project to hemisphere
    let sinTheta = r;
    let cosTheta = sqrt(max(0.0, 1.0 - sinTheta * sinTheta));

    let localDir = float3(
        sinTheta * cos(phi),
        sinTheta * sin(phi),
        cosTheta
    );

    // 4. Build Basis
    let sign = (N.z >= 0.0) ? 1.0 : -1.0;
    let a = -1.0 / (sign + N.z);
    let b = N.x * N.y * a;
    let T = float3(1.0 + sign * N.x * N.x * a, sign * b, -sign * N.x);
    let B = float3(b, sign + N.y * N.y * a, -N.y);

    let L = localDir.x * T + localDir.y * B + localDir.z * N;

    // 5. Calculate PDF
    // PDF for cosine weighted sampling is cos(theta) / PI
    let pdf = cosTheta / float.getPi();

    return BsdfEval(L, pdf);
}

float3 EvalLambertian(float3 albedo) {
    return albedo / float.getPi();
}

float3 EvalDisneyDiffuse(float3 albedo, float roughness, float3 N, float3 L, float3 V) {
    // 1. Calculate Dot Products
    let dotNL = clamp(dot(N, L), 0.0, 1.0); // N dot Light
    let dotNV = clamp(dot(N, V), 0.0, 1.0); // N dot View

    // 2. Calculate Half Vector (Microfacet theory)
    let H = normalize(L + V);
    let dotLH = clamp(dot(L, H), 0.0, 1.0);

    // 3. Calculate Fresnel factor
    // 0.5 represents the base diffuse Fresnel.
    // The 2.0 * roughness term adds the "retro-reflection" for rough surfaces.
    let F_D90 = 0.5 + 2.0 * roughness * dotLH * dotLH;

    // 4. Schlick Approximation for Light and View
    // This creates the "sheen" at grazing angles
    let F_L = 1.0 + (F_D90 - 1.0) * pow(1.0 - dotNL, 5.0);
    let F_V = 1.0 + (F_D90 - 1.0) * pow(1.0 - dotNV, 5.0);

    // 5. Combine
    // Note: We divide by PI here because it is a BRDF.
    return albedo * (1.0 / float.getPi()) * F_L * F_V;
}

float3 EvalOrenNayar(float3 albedo, float roughness, float3 N, float3 L, float3 V) {
    let dotNL = clamp(dot(N, L), 0.0, 1.0);
    let dotNV = clamp(dot(N, V), 0.0, 1.0);

    // Oren-Nayar roughness constants
    let a = roughness * roughness;
    let A = 1.0 - 0.5 * (a / (a + 0.33));
    let B = 0.45 * (a / (a + 0.09));

    // Calculate cosine of azimuth angles difference
    // This is a simplified way to get cos(phi_i - phi_r)
    // derived from the vector projection identity
    let lightPlane = normalize(L - N * dotNL);
    let viewPlane = normalize(V - N * dotNV);
    let cosPhiDiff = dot(lightPlane, viewPlane);

    let alpha = max(acos(dotNL), acos(dotNV));
    let beta  = min(acos(dotNL), acos(dotNV));

    let C = sin(alpha) * tan(beta);

    // Final BRDF
    return (albedo / float.getPi()) * (A + B * max(0.0, cosPhiDiff) * C);
}

float PdfCosineHemisphere(float3 N, float3 L) {
    let dotNL = max(dot(N, L), 0.0);
    return dotNL / float.getPi();
}

// --- Specular Lobe (GGX / Microfacet) ---

// Trowbridge-Reitz (GGX) Normal Distribution
float D_GGX(float dotNH, float alpha) {
    let alpha2 = alpha * alpha;

    let den = (dotNH * dotNH) * (alpha2 - 1.0) + 1.0;
    return alpha2 / (float.getPi() * den * den);
}

// Smith-GGX Correlated Vis term
// Returns: V = G / (4 * dotNL * dotNV)
float V_SmithGGXCorrelated(float dotNL, float dotNV, float alpha) {
    let alpha2 = alpha * alpha;

    // Heitz 2014 optimized form
    let lambdaV = dotNL * sqrt((-dotNV * alpha2 + dotNV) * dotNV + alpha2);
    let lambdaL = dotNV * sqrt((-dotNL * alpha2 + dotNL) * dotNL + alpha2);

    return 0.5 / (lambdaV + lambdaL);
}

BsdfEval SampleMicrofacet(inout uint state, float3 N, float3 V, float alpha) {
    let alpha2 = alpha * alpha;

    // 1. Sample H (VNDF or standard - using standard GGX sampling here for simplicity)
    let u1 = Random(state);
    let u2 = Random(state);

    let phi = 2.0 * float.getPi() * u1;
    let cosTheta = sqrt((1.0 - u2) / (1.0 + (alpha2 - 1.0) * u2));
    let sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    let localH = float3(
        sinTheta * cos(phi),
        sinTheta * sin(phi),
        cosTheta
    );

    // Build Basis
    let sign = (N.z >= 0.0) ? 1.0 : -1.0;
    let a = -1.0 / (sign + N.z);
    let b = N.x * N.y * a;
    let T = float3(1.0 + sign * N.x * N.x * a, sign * b, -sign * N.x);
    let B = float3(b, sign + N.y * N.y * a, -N.y);

    let H = normalize(localH.x * T + localH.y * B + localH.z * N);

    // 2. Reflect to get L
    let dotVH = dot(V, H);
    let L = normalize(2.0 * dotVH * H - V);

    // 3. Compute PDF
    // PDF = (D * dotNH) / (4 * dotVH)
    let dotNH = max(dot(N, H), 0.0);
    let D = D_GGX(dotNH, alpha);

    // Safety check for denominators
    let pdf = (dotVH > 0.0) ? (D * dotNH) / (4.0 * dotVH) : 0.0;

    // We treat the sample value in the struct as the direction here
    return BsdfEval(L, pdf);
}

float3 EvalMicrofacet(float3 N, float3 V, float3 L, float alpha, float3 F0) {
    let dotNL = clamp(dot(N, L), 0.0, 1.0);
    let dotNV = clamp(dot(N, V), 0.0, 1.0);

    if (dotNL <= 0.0 || dotNV <= 0.0) return float3(0.0);

    let H = normalize(V + L);
    let dotNH = clamp(dot(N, H), 0.0, 1.0);
    let dotVH = clamp(dot(V, H), 0.0, 1.0);

    let D = D_GGX(dotNH, alpha);
    let V_term = V_SmithGGXCorrelated(dotNL, dotNV, alpha);
    let F = FresnelSchlick(F0, dotVH);

    // BRDF = D * F * V (Note: V includes the 1/(4*NL*NV) term)
    return D * V_term * F;
}

float PdfMicrofacet(float3 N, float3 V, float3 L, float alpha) {
    if (dot(N, L) <= 0.0) return 0.0;

    let H = normalize(V + L);
    let dotNH = max(dot(N, H), 0.0);
    let dotVH = max(dot(V, H), 0.0);

    let D = D_GGX(dotNH, alpha);
    return (D * dotNH) / (4.0 * dotVH);
}
