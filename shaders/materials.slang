import "utils";
import "lobes";

struct SurfaceInteraction {
    float3 position;
    float3 view;
    float3 normal;
}

struct MaterialProps {
    float3 albedo;
    float metallic;
    float roughness;
    float ior;
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

    let F0 = float3(0.04);
    let alpha = max(0.001, mat.clearcoat_roughness * mat.clearcoat_roughness);

    // 1. Sample Direction & PDF
    let sample = SampleMicrofacetVNDF(rng, si.normal, si.view, alpha);
    result.L = sample.value; // In SampleMicrofacet, value is L

    let pdf = sample.pdf;
    if (pdf <= 0.0 || dot(si.normal, result.L) <= 0.0) {
        return BsdfSample(float3(0), float3(0), false);
    }

    // 2. Evaluate BRDF
    let brdf = EvalMicrofacet(si.normal, si.view, result.L, alpha, F0);

    // 3. Compute Weight: (BRDF * dotNL) / PDF
    let dotNL = clamp(dot(si.normal, result.L), 0.0, 1.0);
    result.weight = brdf * dotNL / sample.pdf;
    result.valid = true;

    return result;
}

BsdfSample SampleBaseSpecular(inout uint rng, SurfaceInteraction si, MaterialProps mat, BaseLayerProps props) {
    BsdfSample result;

    let alpha = max(0.001, mat.roughness * mat.roughness);

    // 1. Sample Direction & PDF
    let sample = SampleMicrofacetVNDF(rng, si.normal, si.view, alpha);
    result.L = sample.value;

    let pdf = sample.pdf;
    if (pdf <= 0.0 || dot(si.normal, result.L) <= 0.0) {
        return BsdfSample(float3(0), float3(0), false);
    }

    // 2. Evaluate BRDF
    let brdf = EvalMicrofacet(si.normal, si.view, result.L, alpha, props.F0);

    // 3. Compute Weight
    let dotNL = clamp(dot(si.normal, result.L), 0.0, 1.0);
    let lobeWeight = brdf * dotNL / sample.pdf;

    // 4. Apply selection probability (Monte Carlo)
    result.weight = lobeWeight / max(props.specProb, 0.001);
    result.valid = true;

    return result;
}

BsdfSample SampleBaseDiffuse(inout uint rng, SurfaceInteraction si, MaterialProps mat, BaseLayerProps props) {
    BsdfSample result;

    // 1. Calculate Diffuse Color
    let transmission = 1.0 - props.F_view;
    let diffuseAlbedo = mat.albedo * (1.0 - mat.metallic) * transmission;

    // 2. Sample Direction & PDF
    let sample = SampleCosineHemisphere(rng, si.normal);
    result.L = sample.value; // In SampleCosine, value is L

    let pdf = sample.pdf;
    if (pdf <= 0.0) {
        return BsdfSample(float3(0), float3(0), false);
    }

    // 3. Evaluate BRDF
    // Use EvalDisneyDiffuse if you want the sheen/retro-reflection, or Lambert for simpler look
    let brdf = EvalDisneyDiffuse(diffuseAlbedo, mat.roughness, si.normal, result.L, si.view);
    // let brdf = EvalLambertian(diffuseAlbedo);

    // 4. Compute Weight
    let dotNL = clamp(dot(si.normal, result.L), 0.0, 1.0);
    let lobeWeight = brdf * dotNL / sample.pdf;

    // 5. Apply selection probability
    result.weight = lobeWeight / max(1.0 - props.specProb, 0.001);
    result.valid = true;

    return result;
}

BsdfSample SampleBaseLayer(inout uint rng, SurfaceInteraction si, MaterialProps mat) {
    BaseLayerProps props;

    let NdotV = clamp(dot(si.normal, si.view), 0.0, 1.0);

    // Dielectric F0
    let dielectricF0 = pow((mat.ior - 1) / (mat.ior + 1), 2) * mat.specular * mat.specular_color;
    props.F0 = lerp(dielectricF0, mat.albedo, mat.metallic);

    // View Fresnel
    props.F_view = FresnelSchlick(props.F0, NdotV);

    // Selection Probability (Luminance of Fresnel)
    let specLuma = dot(props.F_view, float3(0.299, 0.587, 0.114));
    props.specProb = clamp(lerp(specLuma, 1.0, mat.metallic), 0.05, 1.0);

    // Select Lobe
    if (Random(rng) < props.specProb) {
        return SampleBaseSpecular(rng, si, mat, props);
    } else {
        return SampleBaseDiffuse(rng, si, mat, props);
    }
}
