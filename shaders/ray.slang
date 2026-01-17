import "utils";

struct Camera {
    float3 origin;
    float3 lowerLeftCorner;
    float3 horizontal;
    float3 vertical;

    float3 GetDirection(float2 uv) {
        return normalize(this.lowerLeftCorner + uv.x * this.horizontal + uv.y * this.vertical - this.origin);
    }
}

struct PushConstants {
    Camera camera;
    uint2 size;
    uint bounces;
    uint sample;
}

[vk_push_constant]
ConstantBuffer<PushConstants> pc;

struct Instance {
    uint first_vertex;
    uint first_index;
}

struct Vertex {
    float3 normal;
    float _pad;
}

[vk_binding(0, 0)]
RaytracingAccelerationStructure accelStruct;

[vk_binding(1, 0)]
StructuredBuffer<Instance> instances;

[vk_binding(2, 0)]
StructuredBuffer<Vertex> vertices;

[vk_binding(3, 0)]
StructuredBuffer<uint> indices;

[vk_binding(4, 0), format("rgba32f")]
RWTexture2D image;

struct RayPayload {
    bool hit;
    float3 position;
    float3 normal;
}

[shader("raygen")]
void RayGen() {
    // Check id
    let id = DispatchRaysIndex().xy;
    if (any(id >= pc.size)) return;

    // Create ray
    var rng = id.y * pc.size.x + id.x + pc.sample * 729683;
    let uv = float2(id.x + Random(rng), id.y + Random(rng)) / pc.size;

    RayDesc ray;
    ray.Origin = pc.camera.origin;
    ray.Direction = pc.camera.GetDirection(uv);
    ray.TMin = 1E-4f;
    ray.TMax = float.maxValue;

    // Trace ray
    var color = float3(1);
    var light = float3(0);

    for (uint i = 0; i < pc.bounces; i++) {
        RayPayload payload;
        TraceRay(accelStruct, RAY_FLAG_NONE, 0xFF, 0, 0, 0, ray, payload);

        if (!payload.hit) {
            light += color * GetBackground(ray.Direction);
            break;
        }

        ray.Origin = payload.position;
        ray.Direction = RandomCosineHemisphere(rng, payload.normal);

        color *= 0.5;
    }

    // Accumulate color
    let weight = 1.0 / (pc.sample + 1);
    let pos = uint2(id.x, pc.size.y - id.y - 1);
    image[pos] = image[pos] * (1 - weight) + float4(light, 1) * weight;
}

[shader("closesthit")]
void ClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    let b = attributes.barycentrics;
    let bary = float3(1.0 - b.x - b.y, b.x, b.y);

    let instance = instances[CustomInstanceIndex()];

    let index_i = instance.first_index + PrimitiveIndex() * 3;
    let index_a = instance.first_vertex + indices[index_i + 0];
    let index_b = instance.first_vertex + indices[index_i + 1];
    let index_c = instance.first_vertex + indices[index_i + 2];

    let normal = vertices[index_a].normal * bary.x + vertices[index_b].normal * bary.y + vertices[index_c].normal * bary.z;

    payload.hit = true;
    payload.position = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    payload.normal = normalize(mul((float3x3) WorldToObject4x3(), normal));
}

[shader("miss")]
void Miss(inout RayPayload payload) {
    payload.hit = false;
}
