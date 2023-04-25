import io;
import ray;
import hit;
import utils;
import bvh;
import primitives_impl;

const static int SIZE = 8;
const static int MAX_BOUNCES = 8;

#define BACKGROUND

[shader("compute")]
[numthreads(SIZE, SIZE, 1)]
void Main(uint3 id: SV_DispatchThreadID) {
    // Return if outside of image
    if (any(id.xy >= GetSizeInt())) return;

    // Initialize RNG state
    var rngState = id.x + id.y * GetSizeInt().x + sample * 7269;

    // Get UV
    let uvOffset = float2(Random(rngState), Random(rngState));
    let uv = (id.xy + uvOffset) / GetSizeInt();

    // Trace
    let ray = GetCamera().GetRay(uv);
    var color = RayColor(rngState, ray);

    // Blend color with previous sample
    let weight = 1.0 / (sample + 1);
    color = previous[id.xy].xyz * (1 - weight) + color * weight;

    // Store output
    output[id.xy] = float4(color, 0);
}

float3 RayColor(inout uint rngState, Ray ray) {
    var pathColor = float3(1);
    var incomingLight = float3(0);

    for (int i = 0; i < MAX_BOUNCES; i++) {
        var hit = Hit.Far();
        
        IntersectsBVH(sphereBvh, spherePrimitives, ray, 0).CompareWith(hit);
        IntersectsBVH(meshInstanceBvh, meshInstancePrimitives, ray, 0).CompareWith(hit);
        
        if (!hit.didHit) {
            incomingLight += pathColor * GetBackgroundColor(ray);
            break;
        }
        
        let emitted = hit.material.Emitted(hit.uv);
        incomingLight += pathColor * emitted;
        
        let attenuation = hit.material.Scatter(rngState, hit.point, ray.direction, hit.normal, hit.uv, ray);

        // Russian roulette
        let p = max(pathColor.x, max(pathColor.y, pathColor.z));
        if (Random(rngState) > p) break;

        pathColor = (1.0 / p) * (pathColor * attenuation);
    }

    return incomingLight;
}

float3 GetBackgroundColor(Ray ray) {
#ifdef BACKGROUND
    let unitDirection = normalize(ray.direction);
    let t = 0.5 * (unitDirection.y + 1);
    return (1 - t) * float3(1) + t * float3(0.5, 0.7, 1);
#else
    return float3(0);
#endif
}