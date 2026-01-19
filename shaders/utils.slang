uint Tea(uint val0, uint val1) {
    var v0 = val0;
    var v1 = val1;
    var s0 = 0;

    for (uint n = 0; n < 16; n++) {
        s0 += 0x9e3779b9;
        v0 += ((v1 << 4) + 0xa341316c) ^ (v1 + s0) ^ ((v1 >> 5) + 0xc8013ea4);
        v1 += ((v0 << 4) + 0xad90777d) ^ (v0 + s0) ^ ((v0 >> 5) + 0x7e95761e);
    }

    return v0;
}

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

float G_Smith(float dotNL, float dotNV, float roughness) {
    let a2 = roughness * roughness;
    let lambdaV = dotNL * sqrt((-dotNV * a2 + dotNV) * dotNV + a2);
    let lambdaL = dotNV * sqrt((-dotNL * a2 + dotNL) * dotNL + a2);
    return 0.5 / (lambdaV + lambdaL);
}

struct GGXSample {
    float3 L;
    float3 weight;
}

GGXSample SampleGGX(inout uint state, float3 N, float3 V, float roughness, float3 F0) {
    let a2 = roughness * roughness;

    // 1. Sample Microfacet Normal (H)
    let u1 = Random(state);
    let u2 = Random(state);

    let phi = 2.0 * float.getPi() * u1;
    let cosTheta = sqrt((1.0 - u2) / (1.0 + (a2 - 1.0) * u2));
    let sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    let localH = float3(
        sinTheta * cos(phi),
        sinTheta * sin(phi),
        cosTheta
    );

    // 2. Build TBN (Same Duff et al method as CosineHemisphere)
    let sign = (N.z >= 0.0) ? 1.0 : -1.0;
    let a = -1.0 / (sign + N.z);
    let b = N.x * N.y * a;
    let T = float3(1.0 + sign * N.x * N.x * a, sign * b, -sign * N.x);
    let B = float3(b, sign + N.y * N.y * a, -N.y);

    let H = normalize(localH.x * T + localH.y * B + localH.z * N);

    // 3. Calculate Light Direction (Reflect V around H)
    let dotVH = dot(V, H);
    let L = normalize(2.0 * dotVH * H - V);

    // 4. Calculate Weight (Cancel terms in Estimator / PDF)
    let dotNL = clamp(dot(N, L), 0.0, 1.0);
    let dotNV = clamp(dot(N, V), 0.0, 1.0);
    let dotNH = clamp(dot(N, H), 0.0, 1.0);

    if (dotNL > 0.0 && dotVH > 0.0) {
        // Fresnel (Schlick)
        let F = F0 + (1.0 - F0) * pow(1.0 - dotVH, 5.0);

        // Geometry (Vis term = G / (4 * NL * NV))
        // The standard PDF for GGX is (D * NH) / (4 * VH)
        // The BRDF is (D * F * G) / (4 * NL * NV)
        // Weight = BRDF * NL / PDF
        // Result simplifies to: F * (G * VH / (NH * NV))

        // Note: The visibility term G_Smith above is actually V = G / (4 * NL * NV)
        // to fit standard optimizations, so let's use the explicit G here for clarity
        // or just strict Smith G1 * G1.
        // Let's use the correlated SmithVis approximation:
        let Vis = G_Smith(dotNL, dotNV, roughness);

        // Combine: Weight = F * Vis * 4.0 * dotNL * dotNV * dotNL / (dotNL * PDF)?
        // Simplified Estimator weight for GGX Sampling:
        // Weight = F * (dotVH / (dotNH * dotNV)) * G_Smith_Implicit?

        // Let's use the robust standard split:
        // G_Smith returns 0.5 / (...) which is the Vis term.
        // Weight = F * (Vis * 4.0 * dotNL * dotNV) * dotNL / ( (D*NH)/(4*VH) )
        // This gets complex. Let's use the known result for Sample visible normals:
        // Weight = F * G2 / G1.

        // Alternative simple implementation for path tracing weight:
        let G = 4.0 * dotNL * dotNV * Vis; // Extract G from Vis
        let weight = F * (G * dotVH / (dotNV * dotNH));

        return GGXSample(L, weight);
    }

    return GGXSample(float3(0), float3(0));
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

float2 CartesianToSpherical(float3 dir, float rotation) {
    // atan2(z, x) gives the angle on the horizontal plane
    // We add rotation here to spin the skybox
    float phi = atan2(dir.z, dir.x) + rotation;

    // acos(y) gives the vertical angle (0 is up, PI is down)
    // Note: Assuming Y is Up. If Z is Up, swap y and z logic.
    float theta = acos(dir.y);

    // Map to [0, 1] range
    float u = phi * 0.159154943; // 1 / (2 * PI)
    float v = theta * 0.318309886; // 1 / PI

    // Wrap u to stay within [0, 1] if rotation pushed it out
    u = frac(u);

    return float2(u, v);
}

float3 NormalMap(float4 tangent, float3 N, float3 N_map) {
    // A. Transform Tangent to World Space
    let T_geom = normalize(mul((float3x3) ObjectToWorld(), tangent.xyz));

    // B. Gram-Schmidt Re-orthogonalization
    // Interpolation makes T and N no longer perfectly perpendicular.
    // We subtract the part of T that points in the direction of N.
    let T = normalize(T_geom - dot(T_geom, N) * N);

    // C. Calculate Bitangent
    // We use the 'w' component (handedness) to flip the cross product if needed
    // (This handles mirrored UVs automatically)
    let B = cross(N, T) * tangent.w;

    // D. Create TBN Matrix (Tangent -> World)
    let TBN = float3x3(T, B, N);

    // E. Decode Normal ([0,1] -> [-1,1])
    let localNormal = normalize(N_map * 2.0 - 1.0);

    // F. Apply TBN transformation
    // Note: Check if you need to flip Y for OpenGL/DirectX conventions.
    // If your normal map looks "inverted" (bumps look like holes),
    // try: localNormal.y *= -1.0;
    return normalize(mul(localNormal, TBN));
}

float3 HueClamp(float3 color, float limit) {
    let maxVal = max(max(color.r, color.g), color.b);

    if (maxVal > limit) {
        return color * (limit / maxVal);
    }

    return color;
}
