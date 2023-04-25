float Random(inout uint state) {
    state = state * 747796405 + 2891336453;

    var result = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
    result = (result >> 22) ^ result;

    return result / 4294967295.0;
}

float RandomNormalDistribution(inout uint state) {
    let theta = 2 * 3.1415926 * Random(state);
    let rho = sqrt(-2 * log(Random(state)));
    return rho * cos(theta);
}

float3 RandomDirection(inout uint state) {
    let x = RandomNormalDistribution(state);
    let y = RandomNormalDistribution(state);
    let z = RandomNormalDistribution(state);
    return normalize(float3(x, y, z));
}

float3 RandomHemisphereDirection(inout uint state, float3 normal) {
    let dir = RandomDirection(state);
    return dir * sign(dot(normal, dir));
}

static const float PI = 3.1415926535;

float3 RandomCosineHemisphere(inout uint state, float3 normal) {
    float r1 = 2.0f * PI * Random(state);
    float r2 = Random(state);
    float r2s = sqrt(r2);

    float3 w = normal;
    float3 u;
    if (abs(w[0]) > 0.1f)
        u = cross(float3( 0.0, 1.0, 0.0 ), w);
    else
        u = cross(float3( 1.0, 0.0, 0.0 ), w);

    u = normalize(u);
    float3 v = cross(w, u);
    float3 d = (u * cos(r1) * r2s + v * sin(r1) * r2s + w * sqrt(1 - r2));
    d = normalize(d);

    return d;
}

float3 TransformPosition(float3 v, float4x4 m) {
    return float3(
        //dot(m.s012, v) + m.s3,
        dot(float3(m._m00, m._m01, m._m02), v) + m._m03,

        //dot(m.s456, v) + m.s7,
        dot(float3(m._m10, m._m11, m._m12), v) + m._m13,

        //dot(m.s89A, v) + m.sb
        dot(float3(m._m20, m._m21, m._m23), v) + m._m30
    );
}

float3 TransformVector(float3 v, float4x4 m) {
    return float3(
        // dot(m.s012, v) + m.s3,
        dot(float3(m._m00, m._m01, m._m02), v),

        // dot(m.s456, v) + m.s7,
        dot(float3(m._m10, m._m11, m._m12), v),

        // dot(m.s89A, v) + m.sb
        dot(float3(m._m20, m._m21, m._m23), v)
    );
}

float Luminance(float3 c) {
    return 0.212671 * c.x + 0.715160 * c.y + 0.072169 * c.z;
}