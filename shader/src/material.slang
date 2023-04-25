import utils;
import ray;

struct Textures {
    Sampler2D<float3> textures[];
};

[[vk_binding(7, 0)]]
StructuredBuffer<Material> materials;

[[vk_binding(8, 0)]]
ConstantBuffer<Textures> textures;

#define PI 3.14159265358979323
#define INV_PI 0.31830988618379067
#define TWO_PI 6.28318530717958648

struct SampledMaterial {
    float3 albedo;

    float metallic;
    float roughness;

    float ax;
    float ay;
}

struct Material {
    float4 albedo;
    float4 emission;

    float metallic;
    float subsurface;
    float roughness;
    float specularTint;
    float sheen;
    float sheenTint;
    float clearcoat;

    float clearcoatRoughness;
    float specTrans;
    float anisotropic;
    float ior;

    uint albedoTexture;
    uint metallicRoughnessTexture;
    uint emissionTexture;
    uint normalTexture;

    float3 Emitted(float2 uv) {
        var emission = this.emission.xyz;
        if (emissionTexture > 0) emission *= textures.textures[emissionTexture - 1].Sample(uv);

        return emission;
    }

    float3 Scatter(inout uint rngState, float3 point, float3 direction, float3 normal, float2 uv, out Ray scattered) {
        float3 dir;
        float pdf;

        if (normalTexture > 0) {
            float3 T, B;
            Onb(normal, T, B);
            let tbn = transpose(float3x3(T, B, normal));

            let n = textures.textures[normalTexture - 1].Sample(uv);
            normal = normalize(mul(tbn, n * 2 - 1));
        }

        let sampledMat = GetSampledMaterial(uv);

        var eta = dot(direction, normal) < 0 ? (1 / ior) : ior;
        let ffnormal = dot(normal, direction) <= 0 ? normal : -normal;

        let color = DisneySample(rngState, sampledMat, eta, -direction, ffnormal, dir, pdf);

        scattered = Ray(point, dir);
        return color / max(pdf, 0.000001); // don't know why it produces pdfs of 0
    }

    SampledMaterial GetSampledMaterial(float2 uv) {
        SampledMaterial mat;

        // Albedo
        mat.albedo = albedo.xyz;

        if (albedoTexture > 0) {
            mat.albedo *= textures.textures[albedoTexture - 1].Sample(uv);
        }

        // Metallic / Roughness
        mat.metallic = metallic;
        mat.roughness = roughness;

        if (metallicRoughnessTexture > 0) {
            let sample = textures.textures[metallicRoughnessTexture - 1].Sample(uv);

            mat.metallic *= sample.z;
            mat.roughness *= sample.y;
        }

        // AX / AY
        let aspect = sqrt(1 - anisotropic * 0.9);
        mat.ax = max(0.001, mat.roughness / aspect);
        mat.ay = max(0.001, mat.roughness * aspect);

        return mat;
    }

    float3 LambertSample(inout uint rngState, SampledMaterial sampledMat, inout float eta, float3 V, float3 N, out float3 L, out float pdf)
    {
        float r1 = Random(rngState);
        float r2 = Random(rngState);

        float3 T, B;
        Onb(N, T, B);

        L = CosineSampleHemisphere(r1, r2);
        L = T * L.x + B * L.y + N * L.z;

        pdf = dot(N, L) * (1.0 / PI);

        return (1.0 / PI) * sampledMat.albedo * dot(N, L);
    }

    float3 DisneySample(inout uint rngState, SampledMaterial sampledMat, inout float eta, float3 V, float3 N, out float3 L, out float pdf)
    {
        pdf = 0.0;

        float r1 = Random(rngState);
        float r2 = Random(rngState);

        // TODO: Tangent and bitangent should be calculated from mesh (provided, the mesh has proper uvs)
        float3 T, B;
        Onb(N, T, B);

        // Transform to shading space to simplify operations (NDotL = L.z; NDotV = V.z; NDotH = H.z)
        V = ToLocal(T, B, N, V);

        // Tint colors
        float3 Csheen, Cspec0;
        float F0;
        TintColors(sampledMat, eta, F0, Csheen, Cspec0);

        // Model weights
        float dielectricWt = (1.0 - sampledMat.metallic) * (1.0 - specTrans);
        float metalWt = sampledMat.metallic;
        float glassWt = (1.0 - sampledMat.metallic) * specTrans;

        // Lobe probabilities
        float schlickWt = SchlickWeight(V.z);

        float diffPr = dielectricWt * Luminance(sampledMat.albedo);
        float dielectricPr = dielectricWt * Luminance(lerp(Cspec0, float3(1.0), schlickWt));
        float metalPr = metalWt * Luminance(lerp(sampledMat.albedo, float3(1.0), schlickWt));
        float glassPr = glassWt;
        float clearCtPr = 0.25 * clearcoat;

        // Normalize probabilities
        float invTotalWt = 1.0 / (diffPr + dielectricPr + metalPr + glassPr + clearCtPr);
        diffPr *= invTotalWt;
        dielectricPr *= invTotalWt;
        metalPr *= invTotalWt;
        glassPr *= invTotalWt;
        clearCtPr *= invTotalWt;

        // CDF of the sampling probabilities
        float cdf[5];
        cdf[0] = diffPr;
        cdf[1] = cdf[0] + dielectricPr;
        cdf[2] = cdf[1] + metalPr;
        cdf[3] = cdf[2] + glassPr;
        cdf[4] = cdf[3] + clearCtPr;

        // Sample a lobe based on its importance
        float r3 = Random(rngState);

        if (r3 < cdf[0]) // Diffuse
        {
            L = CosineSampleHemisphere(r1, r2);
        }
        else if (r3 < cdf[2]) // Dielectric + Metallic reflection
        {
            float3 H = SampleGGXVNDF(V, sampledMat.ax, sampledMat.ay, r1, r2);

            if (H.z < 0.0)
                H = -H;

            L = normalize(reflect(-V, H));
        }
        else if (r3 < cdf[3]) // Glass
        {
            float3 H = SampleGGXVNDF(V, sampledMat.ax, sampledMat.ay, r1, r2);
            float F = DielectricFresnel(abs(dot(V, H)), eta);

            if (H.z < 0.0)
                H = -H;

            // Rescale random number for reuse
            r3 = (r3 - cdf[2]) / (cdf[3] - cdf[2]);

            // Reflection
            if (r3 < F)
            {
                L = normalize(reflect(-V, H));
            }
            else // Transmission
            {
                L = normalize(refract(-V, H, eta));
            }
        }
        else // Clearcoat
        {
            float3 H = SampleGTR1(clearcoatRoughness, r1, r2);

            if (H.z < 0.0)
                H = -H;

            L = normalize(reflect(-V, H));
        }

        L = ToWorld(T, B, N, L);
        V = ToWorld(T, B, N, V);

        return DisneyEval(rngState, sampledMat, eta, V, N, L, pdf);
    }

    void Onb(float3 N, out float3 T, out float3 B)
    {
        float3 up = abs(N.z) < 0.9999999 ? float3(0, 0, 1) : float3(1, 0, 0);
        T = normalize(cross(up, N));
        B = cross(N, T);
    }

    float3 CosineSampleHemisphere(float r1, float r2)
    {
        float3 dir;
        float r = sqrt(r1);
        float phi = TWO_PI * r2;
        dir.x = r * cos(phi);
        dir.y = r * sin(phi);
        dir.z = sqrt(max(0.0, 1.0 - dir.x * dir.x - dir.y * dir.y));
        return dir;
    }

    float3 ToWorld(float3 X, float3 Y, float3 Z, float3 V)
    {
        return V.x * X + V.y * Y + V.z * Z;
    }

    float3 ToLocal(float3 X, float3 Y, float3 Z, float3 V)
    {
        return float3(dot(V, X), dot(V, Y), dot(V, Z));
    }

    void TintColors(SampledMaterial sampledMat, float eta, out float F0, out float3 Csheen, out float3 Cspec0)
    {
        float lum = Luminance(sampledMat.albedo);
        float3 ctint = lum > 0.0 ? sampledMat.albedo / lum : float3(1.0);

        F0 = (1.0 - eta) / (1.0 + eta);
        F0 *= F0;

        Cspec0 = F0 * lerp(float3(1.0), ctint, specularTint);
        Csheen = lerp(float3(1.0), ctint, sheenTint);
    }

    float3 EvalDisneyDiffuse(SampledMaterial sampledMat, float3 Csheen, float3 V, float3 L, float3 H, out float pdf)
    {
        pdf = 0.0;
        if (L.z <= 0.0)
            return float3(0.0);

        float LDotH = dot(L, H);

        float Rr = 2.0 * sampledMat.roughness * LDotH * LDotH;

        // Diffuse
        float FL = SchlickWeight(L.z);
        float FV = SchlickWeight(V.z);
        float Fretro = Rr * (FL + FV + FL * FV * (Rr - 1.0));
        float Fd = (1.0 - 0.5 * FL) * (1.0 - 0.5 * FV);

        // Fake subsurface
        float Fss90 = 0.5 * Rr;
        float Fss = lerp(1.0, Fss90, FL) * lerp(1.0, Fss90, FV);
        float ss = 1.25 * (Fss * (1.0 / (L.z + V.z) - 0.5) + 0.5);

        // Sheen
        float FH = SchlickWeight(LDotH);
        float3 Fsheen = FH * sheen * Csheen;

        pdf = L.z * INV_PI;
        return INV_PI * sampledMat.albedo * lerp(Fd + Fretro, ss, subsurface) + Fsheen;
    }

    float3 EvalMicrofacetReflection(SampledMaterial sampledMat, float3 V, float3 L, float3 H, float3 F, out float pdf)
    {
        pdf = 0.0;
        if (L.z <= 0.0)
            return float3(0.0);

        float D = GTR2Aniso(H.z, H.x, H.y, sampledMat.ax, sampledMat.ay);
        float G1 = SmithGAniso(abs(V.z), V.x, V.y, sampledMat.ax, sampledMat.ay);
        float G2 = G1 * SmithGAniso(abs(L.z), L.x, L.y, sampledMat.ax, sampledMat.ay);

        pdf = G1 * D / (4.0 * V.z);
        return F * D * G2 / (4.0 * L.z * V.z);
    }

    float3 EvalMicrofacetRefraction(SampledMaterial sampledMat, float eta, float3 V, float3 L, float3 H, float3 F, out float pdf)
    {
        pdf = 0.0;
        if (L.z >= 0.0)
            return float3(0.0);

        float LDotH = dot(L, H);
        float VDotH = dot(V, H);

        float D = GTR2Aniso(H.z, H.x, H.y, sampledMat.ax, sampledMat.ay);
        float G1 = SmithGAniso(abs(V.z), V.x, V.y, sampledMat.ax, sampledMat.ay);
        float G2 = G1 * SmithGAniso(abs(L.z), L.x, L.y, sampledMat.ax, sampledMat.ay);
        float denom = LDotH + VDotH * eta;
        denom *= denom;
        float eta2 = eta * eta;
        float jacobian = abs(LDotH) / denom;

        pdf = G1 * max(0.0, VDotH) * D * jacobian / V.z;
        return pow(sampledMat.albedo, float3(0.5)) * (1.0 - F) * D * G2 * abs(VDotH) * jacobian * eta2 / abs(L.z * V.z);
    }

    float3 EvalClearcoat(float3 V, float3 L, float3 H, out float pdf)
    {
        pdf = 0.0;
        if (L.z <= 0.0)
            return float3(0.0);

        float VDotH = dot(V, H);

        float F = lerp(0.04, 1.0, SchlickWeight(VDotH));
        float D = GTR1(H.z, clearcoatRoughness);
        float G = SmithG(L.z, 0.25) * SmithG(V.z, 0.25);
        float jacobian = 1.0 / (4.0 * VDotH);

        pdf = D * H.z * jacobian;
        return float3(F) * D * G;
    }

    float3 DisneyEval(inout uint rngState, SampledMaterial sampledMat, inout float eta, float3 V, float3 N, float3 L, out float pdf)
    {
        pdf = 0.0;
        float3 f = float3(0.0);

        // TODO: Tangent and bitangent should be calculated from mesh (provided, the mesh has proper uvs)
        float3 T, B;
        Onb(N, T, B);

        // Transform to shading space to simplify operations (NDotL = L.z; NDotV = V.z; NDotH = H.z)
        V = ToLocal(T, B, N, V);
        L = ToLocal(T, B, N, L);

        float3 H;
        if (L.z > 0.0)
            H = normalize(L + V);
        else
            H = normalize(L + V * eta);

        if (H.z < 0.0)
            H = -H;

        // Tint colors
        float3 Csheen, Cspec0;
        float F0;
        TintColors(sampledMat, eta, F0, Csheen, Cspec0);

        // Model weights
        float dielectricWt = (1.0 - sampledMat.metallic) * (1.0 - specTrans);
        float metalWt = sampledMat.metallic;
        float glassWt = (1.0 - sampledMat.metallic) * specTrans;

        // Lobe probabilities
        float schlickWt = SchlickWeight(V.z);

        float diffPr = dielectricWt * Luminance(sampledMat.albedo);
        float dielectricPr = dielectricWt * Luminance(lerp(Cspec0, float3(1.0), schlickWt));
        float metalPr = metalWt * Luminance(lerp(sampledMat.albedo, float3(1.0), schlickWt));
        float glassPr = glassWt;
        float clearCtPr = 0.25 * clearcoat;

        // Normalize probabilities
        float invTotalWt = 1.0 / (diffPr + dielectricPr + metalPr + glassPr + clearCtPr);
        diffPr *= invTotalWt;
        dielectricPr *= invTotalWt;
        metalPr *= invTotalWt;
        glassPr *= invTotalWt;
        clearCtPr *= invTotalWt;

        bool reflect = L.z * V.z > 0;

        float tmpPdf = 0.0;
        float VDotH = abs(dot(V, H));

        // Diffuse
        if (diffPr > 0.0 && reflect)
        {
            f += EvalDisneyDiffuse(sampledMat, Csheen, V, L, H, tmpPdf) * dielectricWt;
            pdf += tmpPdf * diffPr;
        }

        // Dielectric Reflection
        if (dielectricPr > 0.0 && reflect)
        {
            // Normalize for interpolating based on Cspec0
            float F = (DielectricFresnel(VDotH, 1.0 / ior) - F0) / (1.0 - F0);

            f += EvalMicrofacetReflection(sampledMat, V, L, H, lerp(Cspec0, float3(1.0), F), tmpPdf) * dielectricWt;
            pdf += tmpPdf * dielectricPr;
        }

        // Metallic Reflection
        if (metalPr > 0.0 && reflect)
        {
            // Tinted to base color
            float3 F = lerp(sampledMat.albedo, float3(1.0), SchlickWeight(VDotH));

            f += EvalMicrofacetReflection(sampledMat, V, L, H, F, tmpPdf) * metalWt;
            pdf += tmpPdf * metalPr;
        }

        // Glass/Specular BSDF
        if (glassPr > 0.0)
        {
            // Dielectric fresnel (achromatic)
            float F = DielectricFresnel(VDotH, eta);

            if (reflect)
            {
                f += EvalMicrofacetReflection(sampledMat, V, L, H, float3(F), tmpPdf) * glassWt;
                pdf += tmpPdf * glassPr * F;
            }
            else
            {
                f += EvalMicrofacetRefraction(sampledMat, eta, V, L, H, float3(F), tmpPdf) * glassWt;
                pdf += tmpPdf * glassPr * (1.0 - F);
            }
        }

        // Clearcoat
        if (clearCtPr > 0.0 && reflect)
        {
            f += EvalClearcoat(V, L, H, tmpPdf) * 0.25 * clearcoat;
            pdf += tmpPdf * clearCtPr;
        }

        return f * abs(L.z);
    }

    float SchlickWeight(float u) {
        float m = clamp(1.0 - u, 0.0, 1.0);
        float m2 = m * m;
        return m2 * m2 * m;
    }

    float3 SampleGGXVNDF(float3 V, float ax, float ay, float r1, float r2) {
        float3 Vh = normalize(float3(ax * V.x, ay * V.y, V.z));

        float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
        float3 T1 = lensq > 0 ? float3(-Vh.y, Vh.x, 0) * rsqrt(lensq) : float3(1, 0, 0);
        float3 T2 = cross(Vh, T1);

        float r = sqrt(r1);
        float phi = 2.0 * PI * r2;
        float t1 = r * cos(phi);
        float t2 = r * sin(phi);
        float s = 0.5 * (1.0 + Vh.z);
        t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;

        float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;

        return normalize(float3(ax * Nh.x, ay * Nh.y, max(0.0, Nh.z)));
    }

    float DielectricFresnel(float cosThetaI, float eta) {
        float sinThetaTSq = eta * eta * (1.0 - cosThetaI * cosThetaI);

        // Total internal reflection
        if (sinThetaTSq > 1.0)
            return 1.0;

        float cosThetaT = sqrt(max(1.0 - sinThetaTSq, 0.0));

        float rs = (eta * cosThetaT - cosThetaI) / (eta * cosThetaT + cosThetaI);
        float rp = (eta * cosThetaI - cosThetaT) / (eta * cosThetaI + cosThetaT);

        return 0.5 * (rs * rs + rp * rp);
    }

    float GTR2Aniso(float NDotH, float HDotX, float HDotY, float ax, float ay) {
        float a = HDotX / ax;
        float b = HDotY / ay;
        float c = a * a + b * b + NDotH * NDotH;
        return 1.0 / (PI * ax * ay * c * c);
    }

    float3 SampleGTR1(float rgh, float r1, float r2) {
        float a = max(0.001, rgh);
        float a2 = a * a;

        float phi = r1 * TWO_PI;

        float cosTheta = sqrt((1.0 - pow(a2, 1.0 - r2)) / (1.0 - a2));
        float sinTheta = clamp(sqrt(1.0 - (cosTheta * cosTheta)), 0.0, 1.0);
        float sinPhi = sin(phi);
        float cosPhi = cos(phi);

        return float3(sinTheta * cosPhi, sinTheta * sinPhi, cosTheta);
    }

    float SmithGAniso(float NDotV, float VDotX, float VDotY, float ax, float ay) {
        float a = VDotX * ax;
        float b = VDotY * ay;
        float c = NDotV;
        return (2.0 * NDotV) / (NDotV + sqrt(a * a + b * b + c * c));
    }

    float GTR1(float NDotH, float a) {
        if (a >= 1.0)
            return INV_PI;
        float a2 = a * a;
        float t = 1.0 + (a2 - 1.0) * NDotH * NDotH;
        return (a2 - 1.0) / (PI * log(a2) * t);
    }

    float SmithG(float NDotV, float alphaG) {
        float a = alphaG * alphaG;
        float b = NDotV * NDotV;
        return (2.0 * NDotV) / (NDotV + sqrt(a + b - a * b));
    }
};