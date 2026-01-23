import "utils";
import "materials";

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
    float envIntensity;
    float envRotation;
}

[vk_push_constant]
ConstantBuffer<PushConstants> pc;

struct Vertex {
    float3 normal;
    float _pad0;

    float2 uv;
    float2 _pad1;

    float4 tangent;
}

struct Material {
    float4 albedo_factor;
    uint albedo_texture;

    float metallic_factor;
    float roughness_factor;
    uint metallic_roughness_texture;

    float4 emissive_factor;
    uint emissive_texture;

    float clearcoat_factor;
    uint clearcoat_texture;

    float clearcoat_roughness_factor;
    uint clearcoat_roughness_texture;

    uint normal_texture;

    uint opaque;

    uint _pad;

    float3 emissive(float2 uv) {
        return emissive_factor.rgb * SampleTexture(emissive_texture, uv).rgb;
    }

    float alpha(float2 uv) {
        return albedo_factor.a * SampleTexture(albedo_texture, uv).a;
    }
}

struct Instance {
    Vertex* vertices;
    uint* indices;

    Material* material;
}

[vk_binding(0, 0)]
RaytracingAccelerationStructure accelStruct;

[vk_binding(1, 0)]
StructuredBuffer<Instance> instances;

[vk_binding(2, 0)]
ConstantBuffer<Sampler2D<float4>[]> textures;

[vk_binding(3, 0)]
Sampler2D<float3> environmentMap;

[vk_binding(4, 0), format("rgba32f")]
RWTexture2D image;

struct RayPayload {
    uint rng;
    uint depth;

    bool hit;

    float3 new_origin;
    float3 new_direction;

    float3 color;
    float3 emissive;
}

[shader("raygen")]
void RayGen() {
    // Check id
    let id = DispatchRaysIndex().xy;
    if (any(id >= pc.size)) return;

    // Create ray
    var rng = Tea(id.y * pc.size.x + id.x, pc.sample);
    let uv = float2(id.x + Random(rng), id.y + Random(rng)) / pc.size;

    RayDesc ray;
    ray.Origin = pc.camera.origin;
    ray.Direction = pc.camera.GetDirection(uv);
    ray.TMin = 0.0;
    ray.TMax = float.maxValue;

    // Trace ray
    var color = float3(1);
    var light = float3(0);

    RayPayload payload;
    payload.rng = rng;

    for (uint i = 0; i < pc.bounces; i++) {
        // Trace
        payload.depth = i;
        TraceRay(accelStruct, RAY_FLAG_NONE, 0xFF, 0, 0, 0, ray, payload);

        // Miss
        if (!payload.hit) {
            light += color * payload.color;
            break;
        }

        // Hit
        light += color * payload.emissive;

        ray.Origin = payload.new_origin;
        ray.Direction = payload.new_direction;

        color *= payload.color;

        // Russian Roulette
        if (i > 3) {
            let p = clamp(max(color.r, max(color.g, color.b)), 0.05, 1.0);

            // If the ray is very dark, giving it a chance to die
            if (Random(payload.rng) > p) {
                break;
            }

            // If it survives, boost energy so the average remains correct
            color *= 1.0 / p;
        }
    }

    // Accumulate color
    let weight = 1.0 / (pc.sample + 1);
    let pos = uint2(id.x, pc.size.y - id.y - 1);
    image[pos] = image[pos] * (1 - weight) + float4(light, 1) * weight;
}

[shader("anyhit")]
void AnyHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    let instance = instances[CustomInstanceIndex()];
    let vertex = InterpolateAttributes(attributes.barycentrics, instance);

    if (instance.material.alpha(vertex.uv) < Random(payload.rng)) {
        IgnoreHit();
    }
}

[shader("closesthit")]
void ClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    let instance = instances[CustomInstanceIndex()];

    let vertex = InterpolateAttributes(attributes.barycentrics, instance);
    let mat = GetMaterialProps(instance.material, vertex.uv);

    // Fill in surface interaction
    SurfaceInteraction si;
    si.position = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    si.view = -WorldRayDirection();
    si.normal = OrientNormal(normalize(mul((float3x3) ObjectToWorld(), vertex.normal)), si.view);

    // Calculate new origin
    payload.new_origin = si.position + si.normal * (1e-4 + RayTCurrent() * 1e-5);

    // Sample material
    BsdfSample sample;

    let ccProb = GetClearcoatProbability(si, mat);

    if (Random(payload.rng) < ccProb) {
        // --- Clear coat ---
        sample = SampleClearcoatLayer(payload.rng, si, mat);
        sample.weight /= ccProb;

        payload.emissive = float3(0.0);
    } else {
        // --- Base layer ---
        SampleNormalMap(vertex, instance.material, si);

        sample = SampleBaseLayer(payload.rng, si, mat);
        sample.weight /= 1.0 - ccProb;

        payload.emissive = instance.material.emissive(vertex.uv) / (1.0 - ccProb);
    }

    // Fill in payload from sample
    payload.hit = sample.valid;
    payload.new_direction = sample.L;
    payload.color = sample.weight;
}

[shader("miss")]
void MissEnvMap(inout RayPayload payload) {
    let dir = normalize(WorldRayDirection());
    let uv = CartesianToSpherical(dir, pc.envRotation);

    var color = environmentMap.SampleLevelZero(uv) * pc.envIntensity;
    if (payload.depth > 0) color = HueClamp(color, 20);

    payload.hit = false;
    payload.color = color;
}

[shader("miss")]
void MissGeneric(inout RayPayload payload) {
    let dir = normalize(WorldRayDirection());

    payload.hit = false;
    payload.color = GetBackground(dir);
}

Vertex InterpolateAttributes(float2 barycentrics, Instance instance) {
    let bary = float3(1.0 - barycentrics.x - barycentrics.y, barycentrics.x, barycentrics.y);

    let index_i = PrimitiveIndex() * 3;
    let index_a = instance.indices[index_i + 0];
    let index_b = instance.indices[index_i + 1];
    let index_c = instance.indices[index_i + 2];

    Vertex vertex;

    vertex.normal = instance.vertices[index_a].normal * bary.x + instance.vertices[index_b].normal * bary.y + instance.vertices[index_c].normal * bary.z;
    vertex.uv = instance.vertices[index_a].uv * bary.x + instance.vertices[index_b].uv * bary.y + instance.vertices[index_c].uv * bary.z;
    vertex.tangent = instance.vertices[index_a].tangent * bary.x + instance.vertices[index_b].tangent * bary.y + instance.vertices[index_c].tangent * bary.z;

    return vertex;
}

MaterialProps GetMaterialProps(Material* mat, float2 uv) {
    MaterialProps props;

    props.albedo = mat.albedo_factor.rgb * SampleTexture(mat.albedo_texture, uv).rgb;
    props.metallic = mat.metallic_factor * SampleTexture(mat.metallic_roughness_texture, uv).b;
    props.roughness = mat.roughness_factor * SampleTexture(mat.metallic_roughness_texture, uv).g;
    props.clearcoat = mat.clearcoat_factor * SampleTexture(mat.clearcoat_texture, uv).r;
    props.clearcoat_roughness = mat.clearcoat_roughness_factor * SampleTexture(mat.clearcoat_roughness_texture, uv).g;

    return props;
}

float4 SampleTexture(uint texture, float2 uv) {
    if (texture > 0) {
        return textures[texture - 1].SampleLevelZero(uv);
    }

    return float4(1.0);
}

void SampleNormalMap(Vertex vertex, Material* material, inout SurfaceInteraction si) {
    if (material.normal_texture > 0) {
        let normal_geo = si.normal;

        let N_map = textures[material.normal_texture - 1].SampleLevelZero(vertex.uv).xyz;
        si.normal = NormalMap(vertex.tangent, si.normal, N_map);

        if (dot(si.normal, normal_geo) < 0.0) {
            si.normal = normal_geo;
        } else {
            si.normal = OrientNormal(si.normal, si.view);
        }
    }
}
