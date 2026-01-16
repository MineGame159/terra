float Random(inout uint state) {
    state = state * 747796405 + 2891336453;

    var result = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
    result = (result >> 22) ^ result;

    return result / 4294967295.0;
}

float3 RandomCosineHemisphere(inout uint state, float3 normal) {
    let r1 = 2.0 * float.getPi() * Random(state);
    let r2 = Random(state);
    let r2s = sqrt(r2);

    let w = normal;
    float3 u;

    if (abs(w[0]) > 0.1) u = cross(float3(0.0, 1.0, 0.0), w);
    else u = cross(float3(1.0, 0.0, 0.0), w);

    u = normalize(u);

    let v = cross(w, u);
    let d = (u * cos(r1) * r2s + v * sin(r1) * r2s + w * sqrt(1 - r2));

    return normalize(d);
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
