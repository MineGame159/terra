float Random(inout uint state) {
    state = state * 747796405 + 2891336453;

    var result = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
    result = (result >> 22) ^ result;

    return result / 4294967295.0;
}

float3 RandomCosineHemisphere(inout uint state, float3 N) {
    // 1. Get two random numbers
    let u1 = Random(state);
    let u2 = Random(state);

    // 2. Concentric Disk Sampling
    // Map uniform random numbers to [-1, 1]
    let o = 2.0 * float2(u1, u2) - 1.0;

    var r = 0.0;
    var phi = 0.0;

    // Avoid division by zero at origin
    if (abs(o.x) > 1e-6 || abs(o.y) > 1e-6) {
        if (abs(o.x) > abs(o.y)) {
            r = o.x;
            phi = (float.getPi() / 4.0) * (o.y / o.x);
        } else {
            r = o.y;
            phi = (float.getPi() / 2.0) - (float.getPi() / 4.0) * (o.x / o.y);
        }
    }

    // 3. Project disk to hemisphere
    // This creates the Cosine Weighted distribution: Z = sqrt(1 - r^2)
    let sinTheta = r;
    let cosTheta = sqrt(max(0.0, 1.0 - sinTheta * sinTheta));

    let localDir = float3(
        sinTheta * cos(phi),
        sinTheta * sin(phi),
        cosTheta
    );

    // 4. Branchless Basis Construction (Building the TBN matrix)
    // This aligns the local direction to the surface Normal (N)
    // Method: Duff et al (Building an Orthonormal Basis, Revisited)
    let sign = (N.z >= 0.0) ? 1.0 : -1.0;
    let a = -1.0 / (sign + N.z);
    let b = N.x * N.y * a;

    let T = float3(1.0 + sign * N.x * N.x * a, sign * b, -sign * N.x);
    let B = float3(b, sign + N.y * N.y * a, -N.y);

    return localDir.x * T + localDir.y * B + localDir.z * N;
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

float3 GetBackground(float3 direction) {
    var t = 0.5 * (direction.y + 1);
    return (1 - t) * float3(1) + t * float3(0.5, 0.7, 1);
}

uint CustomInstanceIndex() {
    return spirv_asm {
        result:$$uint = OpLoad builtin(InstanceCustomIndexKHR:uint);
    };
}
