uint Tea<let N : uint>(uint val0, uint val1) {
    var v0 = val0;
    var v1 = val1;
    var s0 = 0;

    for (uint n = 0; n < N; n++) {
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

float3 FresnelSchlick(float3 F0, float cosTheta) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

float FresnelDielectric(float cosTheta, float F0_val) {
    return F0_val + (1.0 - F0_val) * pow(1.0 - cosTheta, 5.0);
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

float3 NormalMap(float4 tangent, float3 N, float3 N_map, float scale) {
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

    // E. Decode Normal ([0,1] -> [-1,1]) and apply scale
    let localNormal = normalize(N_map * 2.0 - 1.0) * float3(scale, scale, 1.0);

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

float3 OrientNormal(float3 normal, float3 view) {
    return dot(normal, view) < 0.0 ? -normal : normal;
}

float PowerHeuristic(float f_pdf, float g_pdf) {
    let f2 = f_pdf * f_pdf;
    let g2 = g_pdf * g_pdf;
    return f2 / (f2 + g2);
}
