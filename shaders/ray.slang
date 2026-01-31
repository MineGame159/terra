import "utils";
import "materials";
import "env_map";
import "lights";

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
    uint missIndex;
    float envIntensity;
    float envRotation;
}

[vk_push_constant]
ConstantBuffer<PushConstants> pc;

struct Vertex {
    float2 uv;
    float2 _pad0;

    float3 normal;
    float _pad1;

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

    float ior;

    float specular_factor;
    uint specular_texture;

    float4 specular_color_factor;
    uint specular_color_texture;

    float clearcoat_factor;
    uint clearcoat_texture;

    float clearcoat_roughness_factor;
    uint clearcoat_roughness_texture;

    uint normal_texture;
    float normal_scale;

    uint _pad2;

    float3 emissive(float2 uv) {
        return emissive_factor.rgb * SampleTexture(emissive_texture, uv).rgb;
    }

    float alpha(float2 uv) {
        return albedo_factor.a * SampleTexture(albedo_texture, uv).a;
    }
}

struct Instance {
    uint* indices;
    Vertex* vertices;

    Material* material;
}

[vk_binding(0, 0)]
RaytracingAccelerationStructure accelStruct;

[vk_binding(1, 0)]
StructuredBuffer<Instance> instances;

[vk_binding(2, 0)]
ConstantBuffer<Sampler2D<float4>[]> textures;

[vk_binding(3, 0)]
StructuredBuffer<Light> lights;

[vk_binding(0, 1)]
Sampler2D<float3> envMap;

[vk_binding(1, 1)]
StructuredBuffer<float> envMapCdfMarginal;

[vk_binding(2, 1)]
StructuredBuffer<float> envMapCdfConditional;

[vk_binding(0, 2), format("rgba32f")]
RWTexture2D image;

struct RayPayload {
    uint rng;
    uint depth;

    bool hit;

    float3 new_origin;
    float3 new_direction;

    float3 color;
    float3 emissive;
    float3 direct_light;

    float pdf;
}

struct ShadowPayload {
    uint rng;
    bool hit;
}

[shader("raygen")]
void RayGen() {
    // Check id
    let id = DispatchRaysIndex().xy;
    if (any(id >= pc.size)) return;

    // Create ray
    var rng = Tea<16>(id.y * pc.size.x + id.x, pc.sample);
    let uv = float2(id.x + Random(rng), id.y + Random(rng)) / pc.size;

    RayDesc ray;
    ray.Origin = pc.camera.origin;
    ray.Direction = pc.camera.GetDirection(uv);
    ray.TMin = 0.0;
    ray.TMax = float.maxValue;

    // Trace ray
    var throughput = float3(1);
    var radiance = float3(0);

    RayPayload payload;
    payload.rng = rng;
    payload.pdf = 0.0;

    for (uint i = 0; i < pc.bounces; i++) {
        // Trace
        payload.depth = i;

        TraceRay(accelStruct, RAY_FLAG_NONE, 0xFF, 0, 0, pc.missIndex, ray, payload);

        // Miss
        if (!payload.hit) {
            radiance += throughput * payload.emissive;
            break;
        }

        // Hit
        radiance += throughput * payload.emissive;
        radiance += throughput * payload.direct_light;

        ray.Origin = payload.new_origin;
        ray.Direction = payload.new_direction;

        throughput *= payload.color;

        // Russian Roulette
        if (i > 3) {
            let p = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 1.0);

            // If the ray is very dark, giving it a chance to die
            if (Random(payload.rng) > p) {
                break;
            }

            // If it survives, boost energy so the average remains correct
            throughput *= 1.0 / p;
        }
    }

    // Accumulate color
    let weight = 1.0 / (pc.sample + 1);
    let pos = uint2(id.x, pc.size.y - id.y - 1);
    image[pos] = image[pos] * (1 - weight) + float4(radiance, 1) * weight;
}

[shader("anyhit")]
void AnyHit(inout ShadowPayload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    let instance = instances[CustomInstanceIndex()];
    let vertex = InterpolateAttributes(attributes.barycentrics, instance);

    var rng = Tea<2>(payload.rng, PrimitiveIndex() ^ (CustomInstanceIndex() << 16));

    if (instance.material.alpha(vertex.uv) < Random(rng)) {
        IgnoreHit();
    }
}

[shader("closesthit")]
void ClosestHit(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    let instance = instances[CustomInstanceIndex()];

    let vertex = InterpolateAttributes(attributes.barycentrics, instance);
    let mat = GetMaterialProps(instance.material, vertex.uv);

    SurfaceInteraction si;
    si.position = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    si.view = -WorldRayDirection();
    si.normal_geo = OrientNormal(normalize(mul((float3x3) ObjectToWorld(), vertex.normal)), si.view);

    SampleNormalMap(vertex, instance.material, si);

    // --- Emission ---

    let ccProb = GetClearcoatProbability(si, mat);

    if (length(instance.material.emissive_factor.rgb) > 0.0) {
        payload.emissive = instance.material.emissive(vertex.uv) * (1.0 - ccProb);
    } else {
        payload.emissive = float3(0.0);
    }

    payload.direct_light = 0.0;

    // --- Environment Map NEE ---

    if (pc.missIndex == 1) {
        let sample = SampleEnvironment(GetEnvCDF(), envMap, pc.envRotation, pc.envIntensity, float2(Random(payload.rng), Random(payload.rng)));

        if (dot(si.normal, sample.dir) > 0.0 && dot(si.normal_geo, sample.dir) > 0.0) {
            let occluded = TraceShadowRay(payload.rng, si.get_origin(), sample.dir, 1e9);

            if (!occluded) {
                let eval = EvaluateLayeredMaterial(si, sample.dir, mat);

                let weight = PowerHeuristic(sample.pdf, eval.pdf);
                let dotNL = clamp(dot(si.normal, sample.dir), 0.0, 1.0);

                if (eval.pdf > 0.0) {
                    var li = sample.Li;
                    if (payload.depth > 0) li = HueClamp(li, 20);

                    let misTerm = sample.pdf / (sample.pdf * sample.pdf + eval.pdf * eval.pdf + 1e-10);
                    let contribution = li * eval.value * dotNL * misTerm;

                    payload.direct_light += contribution;
                }
            }
        }
    }

    // --- Direct Light NEE ---

    let lightCount = lights.getCount();

    if (lightCount > 0) {
        let index = min(uint(Random(payload.rng) * float(lightCount)), lightCount - 1);
        let sample = lights[index].Sample(si.position);

        if (dot(si.normal, sample.dir) > 0.0 && dot(si.normal_geo, sample.dir) > 0.0) {
            let occluded = TraceShadowRay(payload.rng, si.get_origin(), sample.dir, sample.dist);

            if (!occluded) {
                let eval = EvaluateLayeredMaterial(si, sample.dir, mat);

                let lightPdf = 1.0 / float(lightCount);
                let dotNL = clamp(dot(si.normal, sample.dir), 0.0, 1.0);
                let weight = float(lightCount);

                payload.direct_light += sample.Li * eval.value * dotNL * weight;
            }
        }
    }

    // --- BSDF ---

    BsdfSample sample;

    // Use random number to select layer
    if (Random(payload.rng) < ccProb) {
        // --- Clearcoat Layer (Uses Geometric Normal) ---
        sample = SampleClearcoatLayer(payload.rng, si, mat);

        // Adjust weight for the selection probability
        if (ccProb > 0.0) sample.weight /= ccProb;

    } else {
        // --- Base Layer (Uses Mapped / Shading Normal) ---
        sample = SampleBaseLayer(payload.rng, si, mat);

        // Adjust weight for the selection probability
        if ((1.0 - ccProb) > 0.0) sample.weight /= (1.0 - ccProb);
    }

    payload.hit = sample.valid;
    payload.new_origin = si.get_origin();
    payload.new_direction = sample.L;
    payload.color = float3(0.0);
    payload.pdf = 0.0;

    if (sample.valid) {
        let eval = EvaluateLayeredMaterial(si, sample.L, mat);
        let dotNL = clamp(dot(si.normal, sample.L), 0.0, 1.0);

        if (eval.pdf > 0.0) {
            payload.color = eval.value * dotNL / eval.pdf;
            payload.pdf = eval.pdf;
        }
    }
}

[shader("miss")]
void MissEnvMap(inout RayPayload payload) {
    let dir = normalize(WorldRayDirection());
    let uv = CartesianToSpherical(dir, pc.envRotation);

    var color = envMap.SampleLevelZero(uv) * pc.envIntensity;
    if (payload.depth > 0) color = HueClamp(color, 20);

    var mis_weight = 1.0;

    if (payload.depth > 0) {
        let bsdf_pdf = payload.pdf;
        let light_pdf = PdfEnvironment(GetEnvCDF(), dir, pc.envRotation);

        mis_weight = PowerHeuristic(bsdf_pdf, light_pdf);
    }

    payload.hit = false;
    payload.emissive = color * mis_weight;
}

[shader("miss")]
void MissGeneric(inout RayPayload payload) {
    let dir = normalize(WorldRayDirection());

    payload.hit = false;
    payload.emissive = GetBackground(dir);
}

[shader("miss")]
void MissShadow(inout ShadowPayload payload) {
    payload.hit = false;
}

bool TraceShadowRay(uint rng, float3 origin, float3 dir, float dist) {
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 1e-4;
    ray.TMax = dist - 1e-4;

    ShadowPayload payload;
    payload.rng = rng;
    payload.hit = true;

    TraceRay(
        accelStruct,
        RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
        0xFF,
        0, 0, 2,
        ray,
        payload
    );

    return payload.hit;
}

Vertex InterpolateAttributes(float2 barycentrics, Instance instance) {
    let bary = float3(1.0 - barycentrics.x - barycentrics.y, barycentrics.x, barycentrics.y);

    let index_i = PrimitiveIndex() * 3;
    let index_a = instance.indices[index_i + 0];
    let index_b = instance.indices[index_i + 1];
    let index_c = instance.indices[index_i + 2];

    Vertex vertex;

    vertex.uv = instance.vertices[index_a].uv * bary.x + instance.vertices[index_b].uv * bary.y + instance.vertices[index_c].uv * bary.z;
    vertex.normal = instance.vertices[index_a].normal * bary.x + instance.vertices[index_b].normal * bary.y + instance.vertices[index_c].normal * bary.z;
    vertex.tangent = instance.vertices[index_a].tangent * bary.x + instance.vertices[index_b].tangent * bary.y + instance.vertices[index_c].tangent * bary.z;

    return vertex;
}

MaterialProps GetMaterialProps(Material* mat, float2 uv) {
    MaterialProps props;

    props.albedo = mat.albedo_factor.rgb * SampleTexture(mat.albedo_texture, uv).rgb;
    props.metallic = mat.metallic_factor * SampleTexture(mat.metallic_roughness_texture, uv).b;
    props.roughness = mat.roughness_factor * SampleTexture(mat.metallic_roughness_texture, uv).g;
    props.ior = mat.ior;
    props.specular = mat.specular_factor * SampleTexture(mat.specular_texture, uv).a;
    props.specular_color = mat.specular_color_factor.rgb * SampleTexture(mat.specular_color_texture, uv).rgb;
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
    si.normal = si.normal_geo;

    if (material.normal_texture > 0) {
        let N_map = textures[material.normal_texture - 1].SampleLevelZero(vertex.uv).xyz;
        si.normal = NormalMap(vertex.tangent, si.normal, N_map, material.normal_scale);

        if (dot(si.normal, si.normal_geo) < 0.0) {
            si.normal = si.normal_geo;
        } else {
            si.normal = OrientNormal(si.normal, si.view);
        }
    }
}

EnvMapCDF GetEnvCDF() {
    EnvMapCDF cdf;

    cdf.marginal = envMapCdfMarginal;
    cdf.conditional = envMapCdfConditional;

    envMap.GetDimensions(cdf.size.x, cdf.size.y);

    return cdf;
}
