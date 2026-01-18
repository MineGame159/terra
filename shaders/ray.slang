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

    uint normal_texture;

    float3 albedo(float2 uv) {
        var albedo = albedo_factor.rgb;

        if (albedo_texture > 0) {
            albedo *= textures[albedo_texture - 1].SampleLevelZero(uv).rgb;
        }

        return albedo;
    }

    float metallic(float2 uv) {
        var metallic = metallic_factor;

        if (metallic_roughness_texture > 0) {
            metallic *= textures[metallic_roughness_texture - 1].SampleLevelZero(uv).b;
        }

        return metallic;
    }

    float roughness(float2 uv) {
        var roughness = roughness_factor;

        if (metallic_roughness_texture > 0) {
            roughness *= textures[metallic_roughness_texture - 1].SampleLevelZero(uv).g;
        }

        return roughness;
    }

    float3 emissive(float2 uv) {
        var emissive = emissive_factor.rgb;

        if (emissive_texture > 0) {
            emissive *= textures[emissive_texture - 1].SampleLevelZero(uv).rgb;
        }

        return emissive;
    }
}

struct Instance {
    Vertex* vertices;
    uint* indices;

    Material material;
}

[vk_binding(0, 0)]
RaytracingAccelerationStructure accelStruct;

[vk_binding(1, 0)]
StructuredBuffer<Instance> instances;

[vk_binding(2, 0)]
ConstantBuffer<Sampler2D<float3>[]> textures;

[vk_binding(3, 0)]
Sampler2D<float3> environmentMap;

[vk_binding(4, 0), format("rgba32f")]
RWTexture2D image;

struct RayPayload {
    uint rng;

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
    var rng = id.y * pc.size.x + id.x + pc.sample * 729683;
    let uv = float2(id.x + Random(rng), id.y + Random(rng)) / pc.size;

    RayDesc ray;
    ray.Origin = pc.camera.origin;
    ray.Direction = pc.camera.GetDirection(uv);
    ray.TMin = 0.0;
    ray.TMax = float.maxValue;

    // Trace ray
    var color = float3(1);
    var light = float3(0);

    for (uint i = 0; i < pc.bounces; i++) {
        RayPayload payload;
        payload.rng = rng * (i + 1);

        TraceRay(accelStruct, RAY_FLAG_NONE, 0xFF, 0, 0, 0, ray, payload);

        if (!payload.hit) {
            light += color * payload.color;
            break;
        }

        light += color * payload.emissive;

        ray.Origin = payload.new_origin;
        ray.Direction = payload.new_direction;

        color *= payload.color;
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

    let index_i = PrimitiveIndex() * 3;
    let index_a = instance.indices[index_i + 0];
    let index_b = instance.indices[index_i + 1];
    let index_c = instance.indices[index_i + 2];

    let normal = instance.vertices[index_a].normal * bary.x + instance.vertices[index_b].normal * bary.y + instance.vertices[index_c].normal * bary.z;
    let uv = instance.vertices[index_a].uv * bary.x + instance.vertices[index_b].uv * bary.y + instance.vertices[index_c].uv * bary.z;
    let tangent = instance.vertices[index_a].tangent * bary.x + instance.vertices[index_b].tangent * bary.y + instance.vertices[index_c].tangent * bary.z;

    let geoN = normalize(mul((float3x3) ObjectToWorld(), normal));
    var N = geoN;

    payload.hit = true;

    // Normal mapping
    if (instance.material.normal_texture > 0) {
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

        // E. Sample Normal Map
        // Assume texture is linear RGB (standard for normal maps)
        let rawNormal = textures[instance.material.normal_texture - 1].SampleLevelZero(uv).rgb;

        // F. Decode Normal ([0,1] -> [-1,1])
        let localNormal = normalize(rawNormal * 2.0 - 1.0);

        // G. Apply TBN transformation
        // Note: Check if you need to flip Y for OpenGL/DirectX conventions.
        // If your normal map looks "inverted" (bumps look like holes),
        // try: localNormal.y *= -1.0;

        N = normalize(mul(localNormal, TBN));
    }

    // Material
    let albedo = instance.material.albedo(uv);
    let roughness = max(instance.material.roughness(uv), 0.001);
    let metallic = instance.material.metallic(uv);

    // View direction
    let V = -WorldRayDirection();
    let ffN = dot(N, V) < 0.0 ? -N : N;
    let ffgeoN = dot(N, V) < 0.0 ? -geoN : geoN;

    // F0: Surface reflection at 0 degrees
    // Dielectric: 0.04, Metal: albedo
    let F0 = lerp(float3(0.04), albedo, metallic);

    // Calculate Fresnel at view angle to decide probability of specular reflection
    let F_view = F0 + (1.0 - F0) * pow(1.0 - clamp(dot(ffN, V), 0.0, 1.0), 5.0);
    // Approximate luminosity of Fresnel for probability
    let specProb = dot(F_view, float3(0.299, 0.587, 0.114));

    // Boost specular probability for metals
    var selectionProb = lerp(specProb, 1.0, metallic);
    // Clamp to ensure we don't always/never sample one path
    selectionProb = clamp(selectionProb, 0.05, 0.95);

    payload.new_origin = WorldRayOrigin() + WorldRayDirection() * RayTCurrent() + ffgeoN * 1e-4;

    if (Random(payload.rng) < selectionProb) {
        // --- Specular Path (GGX) ---
        let sample = SampleGGX(payload.rng, ffN, V, roughness * roughness, F0);

        if (dot(sample.weight, sample.weight) > 0.0) {
            payload.new_direction = sample.L;
            payload.color = sample.weight / selectionProb;
        } else {
            payload.hit = false;
            payload.color = float3(0);
        }
    } else {
        // --- Diffuse Path (Disney) ---
        let transmission = 1.0 - F_view;
        let diffuseAlbedo = albedo * (1.0 - metallic) * transmission;

        payload.new_direction = RandomCosineHemisphere(payload.rng, ffN);
        let L = payload.new_direction;

        // Evaluate BRDF
        let brdf = EvalDisneyDiffuse(diffuseAlbedo, roughness, ffN, L, V);

        // Throughput = (BRDF * PI) / (1.0 - Probability)
        payload.color = (brdf * float.getPi()) / (1.0 - selectionProb);
    }

    // Emissive
    payload.emissive = instance.material.emissive(uv);
}

[shader("miss")]
void Miss(inout RayPayload payload) {
    let dir = normalize(WorldRayDirection());
    let uv = CartesianToSpherical(dir, pc.envRotation);
    let envColor = min(environmentMap.SampleLevelZero(uv), float3(20));

    payload.hit = false;
    payload.color = envColor * pc.envIntensity;
}
