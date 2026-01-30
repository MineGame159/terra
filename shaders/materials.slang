import "utils";
import "lobes";

struct SurfaceInteraction {
    float3 position;
    float3 view;
    float3 normal;
    float3 normal_geo;
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
    let ccFresnel = FresnelDielectric(clamp(dot(si.normal_geo, si.view), 0.0, 1.0), 0.04);

    // Probability of hitting the clearcoat is determined by strength and Fresnel
    let p = clamp(ccFresnel * mat.clearcoat, 0.0, 0.99);

    return (p < 0.01) ? 0.0 : p;
}

BsdfSample SampleClearcoatLayer(inout uint rng, SurfaceInteraction si, MaterialProps mat) {
    BsdfSample result;

    let F0 = float3(0.04);
    let alpha = max(0.001, mat.clearcoat_roughness * mat.clearcoat_roughness);

    // 1. Sample Direction & PDF
    let sample = SampleMicrofacetVNDF(rng, si.normal_geo, si.view, alpha);
    result.L = sample.value; // In SampleMicrofacet, value is L

    let pdf = sample.pdf;
    if (pdf <= 0.0 || dot(si.normal_geo, result.L) <= 0.0) {
        return BsdfSample(float3(0), float3(0), false);
    }

    // 2. Evaluate BRDF
    let brdf = EvalMicrofacet(si.normal_geo, si.view, result.L, alpha, F0);

    // 3. Compute Weight: (BRDF * dotNL) / PDF
    let dotNL = clamp(dot(si.normal_geo, result.L), 0.0, 1.0);
    result.weight = brdf * dotNL / sample.pdf;
    result.valid = true;

    return result;
}

BsdfEval EvalClearcoatLayer(SurfaceInteraction si, float3 L, MaterialProps mat) {
    let alpha = max(0.001, mat.clearcoat_roughness * mat.clearcoat_roughness);

    let value = EvalMicrofacet(si.normal_geo, si.view, L, alpha, float3(0.04)) * mat.clearcoat;
    let pdf = PdfMicrofacetVNDF(si.normal_geo, si.view, L, alpha);

    return BsdfEval(value, pdf);
}

BsdfSample SampleBaseLayer(inout uint rng, SurfaceInteraction si, MaterialProps mat) {
    let props = GetBaseLayerProps(si, mat);

    BsdfSample result;
    var pdf = 0.0;
    var brdf = float3(0.0);
    var L = float3(0.0);

    if (Random(rng) < props.specProb) {
        let alpha = max(0.001, mat.roughness * mat.roughness);
        let s = SampleMicrofacetVNDF(rng, si.normal, si.view, alpha);

        L = s.value;
        pdf = s.pdf;
    } else {
        let s = SampleCosineHemisphere(rng, si.normal);

        L = s.value;
        pdf = s.pdf;
    }

    if (dot(si.normal, L) <= 0.0 || pdf <= 0.0) {
        return BsdfSample(float3(0), float3(0), false);
    }

    let eval = EvalBaseLayer(si, L, mat, props);

    result.L = L;
    result.valid = true;

    // Weight = f_r * dot(N,L) / pdf_mixed
    result.weight = eval.value * clamp(dot(si.normal, L), 0.0, 1.0) / eval.pdf;

    return result;
}

BsdfEval EvalBaseLayer(SurfaceInteraction si, float3 L, MaterialProps mat, BaseLayerProps props) {
    let alpha = max(0.001, mat.roughness * mat.roughness);

    // 1. Specular Term
    let specVal = EvalMicrofacet(si.normal, si.view, L, alpha, props.F0);
    let specPdf = PdfMicrofacetVNDF(si.normal, si.view, L, alpha);

    // 2. Diffuse Term
    let transmission = 1.0 - props.F_view;
    let diffuseAlbedo = mat.albedo * (1.0 - mat.metallic) * transmission;

    let diffVal = EvalDisneyDiffuse(diffuseAlbedo, mat.roughness, si.normal, L, si.view);
    let diffPdf = PdfCosineHemisphere(si.normal, L);

    // 3. Combine
    let totalVal = specVal + diffVal;
    let totalPdf = props.specProb * specPdf + (1.0 - props.specProb) * diffPdf;

    return BsdfEval(totalVal, totalPdf);
}

BaseLayerProps GetBaseLayerProps(SurfaceInteraction si, MaterialProps mat) {
    BaseLayerProps props;

    let NdotV = clamp(dot(si.normal, si.view), 0.0, 1.0);

    // Dielectric F0
    let dielectricF0 = pow((mat.ior - 1.0) / (mat.ior + 1.0), 2.0) * mat.specular * mat.specular_color;
    props.F0 = lerp(dielectricF0, mat.albedo, mat.metallic);

    // View Fresnel
    props.F_view = FresnelSchlick(props.F0, NdotV);

    // Selection Probability (Luminance of Fresnel)
    let specLuma = dot(props.F_view, float3(0.299, 0.587, 0.114));
    props.specProb = clamp(lerp(specLuma, 1.0, mat.metallic), 0.05, 1.0);

    return props;
}

BsdfEval EvaluateLayeredMaterial(SurfaceInteraction si, float3 L, MaterialProps mat) {
    // 1. Calculate Coat/Base probabilities
    let ccProb = GetClearcoatProbability(si, mat);

    // 2. Clearcoat Contribution
    let coat = EvalClearcoatLayer(si, L, mat);

    // 3. Base Layer Contribution
    // Initialize props using the extracted helper
    let props = GetBaseLayerProps(si, mat);
    let base = EvalBaseLayer(si, L, mat, props);

    // 4. Combine Layers
    // BSDF = Coat + (1 - CoatProb) * Base
    // PDF  = CoatProb * CoatPdf + (1 - CoatProb) * BasePdf

    let finalVal = coat.value + base.value * (1.0 - ccProb);
    let finalPdf = coat.pdf * ccProb + base.pdf * (1.0 - ccProb);

    return BsdfEval(finalVal, finalPdf);
}
