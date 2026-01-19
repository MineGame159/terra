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

    float clearcoat_factor;
    uint clearcoat_texture;

    float clearcoat_roughness_factor;
    uint clearcoat_roughness_texture;

    uint normal_texture;

    uint opaque;

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

    float clearcoat(float2 uv) {
        var clearcoat = clearcoat_factor;

        if (clearcoat_texture > 0) {
            clearcoat *= textures[clearcoat_texture - 1].SampleLevelZero(uv).r;
        }

        return clearcoat;
    }

    float clearcoat_roughness(float2 uv) {
        var clearcoat_roughness = clearcoat_roughness_factor;

        if (clearcoat_roughness_texture > 0) {
            clearcoat_roughness *= textures[clearcoat_roughness_texture - 1].SampleLevelZero(uv).g;
        }

        return clearcoat_roughness;
    }

    float alpha(float2 uv) {
        var alpha = albedo_factor.a;

        if (albedo_texture > 0) {
            alpha *= textures[albedo_texture - 1].SampleLevelZero(uv).a;
        }

        return alpha;
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
    let vertex = interpolate_attributes(attributes.barycentrics, instance);

    if (instance.material.alpha(vertex.uv) < Random(payload.rng)) {
        IgnoreHit();
    }
}

[shader("closesthit")]
void ClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    let instance = instances[CustomInstanceIndex()];
    let vertex = interpolate_attributes(attributes.barycentrics, instance);

    let geoN = normalize(mul((float3x3) ObjectToWorld(), vertex.normal));

    payload.hit = true;

    // Material
    let clearcoat = instance.material.clearcoat(vertex.uv);
    let clearcoat_roughness = instance.material.clearcoat_roughness(vertex.uv);

    // View direction
    let V = -WorldRayDirection();
    let ffgeoN = dot(geoN, V) < 0.0 ? -geoN : geoN;

    // Dielectric Fresnel (IOR 1.5 -> F0 = 0.04)
    let ccF0 = float3(0.04);
    let ccFresnel = 0.04 + (1.0 - 0.04) * pow(1.0 - clamp(dot(ffgeoN, V), 0.0, 1.0), 5.0);

    // Probability of hitting the clearcoat is determined by strength and Fresnel
    let ccProb = clamp(ccFresnel * clearcoat, 0.0, 0.99);

    // New origin
    payload.new_origin = WorldRayOrigin() + WorldRayDirection() * RayTCurrent() + ffgeoN * (1e-4 + RayTCurrent() * 1e-5);

    if (Random(payload.rng) < ccProb) {
        // --- Clear coat ---

        // Reuse SampleGGX with clearcoat roughness and F0=0.04
        let sample = SampleGGX(payload.rng, ffgeoN, V, clearcoat_roughness * clearcoat_roughness, ccF0);

        if (dot(sample.weight, sample.weight) > 0.0) {
            payload.new_direction = sample.L;
            // Weight must be normalized by the probability of choosing this path
            payload.color = sample.weight / ccProb;
        } else {
            payload.hit = false;
            payload.color = float3(0);
        }

        // Emissive doesn't typically come from the clearcoat layer itself
        payload.emissive = float3(0);
    } else {
        // --- Base layer ---
        let baseLayerWeight = 1.0 / (1.0 - ccProb);

        // Material
        let albedo = instance.material.albedo(vertex.uv);
        let roughness = max(instance.material.roughness(vertex.uv), 0.001);
        let metallic = instance.material.metallic(vertex.uv);

        // Normal mapping
        var N = geoN;

        if (instance.material.normal_texture > 0) {
            let N_map = textures[instance.material.normal_texture - 1].SampleLevelZero(vertex.uv).xyz;
            N = NormalMap(vertex.tangent, N, N_map);

            if (dot(N, geoN) < 0.0) {
                N = geoN;
            }
        }

        let ffN = dot(N, V) < 0.0 ? -N : N;

        // F0: Surface reflection at 0 degrees
        // Dielectric: 0.04, Metal: albedo
        let F0 = lerp(float3(0.04), albedo, metallic);

        // Calculate Fresnel at view angle to decide probability of specular reflection
        let F_view = F0 + (1.0 - F0) * pow(1.0 - clamp(dot(ffN, V), 0.0, 1.0), 5.0);
        // Approximate luminosity of Fresnel for probability
        let specProb = dot(F_view, float3(0.299, 0.587, 0.114));

        // Boost specular probability for metals
        let selectionProb = clamp(lerp(specProb, 1.0, metallic), 0.05, 1.0);

        if (Random(payload.rng) < selectionProb) {
            // --- Specular Path (GGX) ---
            let sample = SampleGGX(payload.rng, ffN, V, roughness * roughness, F0);

            if (dot(sample.weight, sample.weight) > 0.0) {
                payload.new_direction = sample.L;
                payload.color = (sample.weight / max(selectionProb, 0.001)) * baseLayerWeight;
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
            payload.color = ((brdf * float.getPi()) / max(1.0 - selectionProb, 0.001)) * baseLayerWeight;
        }

        // Emissive
        payload.emissive = instance.material.emissive(vertex.uv) * baseLayerWeight;
    }
}

[shader("miss")]
void Miss(inout RayPayload payload) {
    let dir = normalize(WorldRayDirection());
    let uv = CartesianToSpherical(dir, pc.envRotation);

    var color = environmentMap.SampleLevelZero(uv) * pc.envIntensity;
    if (payload.depth > 0) color = HueClamp(color, 20);

    payload.hit = false;
    payload.color = color;
}

Vertex interpolate_attributes(float2 barycentrics, Instance instance) {
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
