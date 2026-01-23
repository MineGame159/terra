import "utils";

struct SurfaceInteraction {
    float3 position;
    float3 view;
    float3 normal;
}

struct MaterialProps {
    float3 albedo;
    float metallic;
    float roughness;
    float specular;
    float3 specular_color;
    float clearcoat;
    float clearcoat_roughness;
}

struct BaseLayerProps {
    float3 F0;          // Surface reflection at 0 degrees
    float3 F_view;      // Fresnel at view angle (for energy conservation)
    float specProb;     // Probability of choosing specular path
}

struct BsdfSample {
    float3 L;           // New direction
    float3 weight;      // Throughput (BRDF * N.L / PDF)
    bool valid;         // Is this sample valid
}

float GetClearcoatProbability(SurfaceInteraction si, MaterialProps mat) {
    let ccFresnel = FresnelDielectric(clamp(dot(si.normal, si.view), 0.0, 1.0), 0.04);

    // Probability of hitting the clearcoat is determined by strength and Fresnel
    return clamp(ccFresnel * mat.clearcoat, 0.0, 0.99);
}

BsdfSample SampleClearcoatLayer(inout uint rng, SurfaceInteraction si, MaterialProps mat) {
    BsdfSample result;

    // Dielectric F0 for clearcoat is usually 0.04
    let ccF0 = float3(0.04);

    // Use Geometric normal for clearcoat (it sits on top of normal map)
    let sample = SampleGGX(rng, si.normal, si.view, mat.clearcoat_roughness * mat.clearcoat_roughness, ccF0);

    result.L = sample.L;
    result.weight = sample.weight;
    result.valid = dot(sample.weight, sample.weight) > 0.0;

    return result;
}

BsdfSample SampleBaseSpecular(inout uint rng, SurfaceInteraction si, MaterialProps mat, BaseLayerProps props) {
    BsdfSample result;

    let sample = SampleGGX(rng, si.normal, si.view, mat.roughness * mat.roughness, props.F0);

    result.L = sample.L;
    result.weight = sample.weight / max(props.specProb, 0.001);
    result.valid = dot(sample.weight, sample.weight) > 0.0;

    return result;
}

BsdfSample SampleBaseDiffuse(inout uint rng, SurfaceInteraction si, MaterialProps mat, BaseLayerProps props) {
    BsdfSample result;

    // Energy Conservation: Diffuse is what is left after Specular reflection
    let transmission = 1.0 - props.F_view;
    let diffuseAlbedo = mat.albedo * (1.0 - mat.metallic) * transmission;

    // Generate Direction (Cosine Weighted)
    result.L = RandomCosineHemisphere(rng, si.normal);

    // Evaluate BRDF
    // Note: If you want to switch to Lambert, replace EvalDisneyDiffuse with (diffuseAlbedo / PI)
    let brdf = EvalDisneyDiffuse(diffuseAlbedo, mat.roughness, si.normal, result.L, si.view);

    // Standard Cosine Sample Weight: (BRDF * PI)
    // We also divide by (1.0 - specProb) because we only trace this path (1-specProb) of the time.
    result.weight = (brdf * float.getPi()) / max(1.0 - props.specProb, 0.001);
    result.valid = true;

    return result;
}

BsdfSample SampleBaseLayer(inout uint rng, SurfaceInteraction si, MaterialProps mat) {
    BaseLayerProps props;

    let NdotV = clamp(dot(si.normal, si.view), 0.0, 1.0);

    // 2. Base F0
    let dielectricF0 = 0.04 * mat.specular * mat.specular_color;
    props.F0 = lerp(dielectricF0, mat.albedo, mat.metallic);

    // 3. Fresnel at view angle
    props.F_view = FresnelSchlick(props.F0, NdotV);

    // 4. Calculate Selection Probability (Specular vs Diffuse)
    // Approx luminance of the Fresnel return
    let specLuma = dot(props.F_view, float3(0.299, 0.587, 0.114));

    // Metals (metallic=1) are 100% specular.
    // Dielectrics mix based on Fresnel strength.
    props.specProb = clamp(lerp(specLuma, 1.0, mat.metallic), 0.05, 1.0);

    if (Random(rng) < props.specProb) {
        return SampleBaseSpecular(rng, si, mat, props);
    } else {
        return SampleBaseDiffuse(rng, si, mat, props);
    }
}
