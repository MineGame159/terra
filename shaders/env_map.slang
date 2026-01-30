import "utils";

// The struct holding the pre-calculated CDF data
struct EnvMapCDF {
    // Marginal CDF: Probability of selecting a specific row (Y)
    // Size: height (+1 usually for the total sum)
    StructuredBuffer<float> marginal;

    // Conditional CDF: Probability of selecting a pixel (X) given a row
    // Size: width * height
    StructuredBuffer<float> conditional;

    // Total sum of weights (luminance * solid_angle)
    float integral;
    uint2 size;
}

// Result of sampling the environment
struct EnvSample {
    float3 dir;  // Direction to light
    float3 Li;   // Radiance (Color)
    float pdf;   // PDF with respect to Solid Angle
}

// Binary search through a CDF to find the index
uint SampleCDF(StructuredBuffer<float> cdf, uint offset, uint count, float val, out float pdf) {
    var left = 0u;
    var right = count - 1;

    // Binary Search
    while (left < right) {
        let mid = (left + right) / 2;

        if (val <= cdf[offset + mid]) {
            right = mid;
        } else {
            left = mid + 1;
        }
    }

    let index = left;

    // Calculate discrete probability: P[i] = CDF[i] - CDF[i-1]
    let prev = (index == 0) ? 0.0 : cdf[offset + index - 1];
    let current = cdf[offset + index];
    pdf = current - prev;

    return index;
}

EnvSample SampleEnvironment(EnvMapCDF cdf, Sampler2D<float3> envMap, float rotation, float intensity, float2 rnd) {
    // 1. Sample the Marginal CDF (Select a Row / Theta)
    float rowPdf;

    // We search the marginal buffer (size = height)
    // Note: Normalize rnd.y by total integral if your CDF isn't normalized to 1.0
    // Assuming CDF is normalized [0..1]:
    let y = SampleCDF(cdf.marginal, 0, cdf.size.y, rnd.y, rowPdf);

    // 2. Sample the Conditional CDF (Select a Column / Phi given Row Y)
    float colPdf;
    let x = SampleCDF(cdf.conditional, y * cdf.size.x, cdf.size.x, rnd.x, colPdf);

    // 3. Convert (x, y) index to UV and Angles
    // Add 0.5 to sample center of pixel
    let u = (float(x) + 0.5) / float(cdf.size.x);
    let v = (float(y) + 0.5) / float(cdf.size.y);

    // 4. Calculate Theta and Phi
    let theta = v * float.getPi();
    let phi = u * 2.0 * float.getPi() - rotation; // Apply rotation here

    // 5. Calculate Direction
    let sinTheta = sin(theta);
    let dir = float3(
        sinTheta * cos(phi),
        cos(theta), // Map Cos(Theta) to Y (Up)
        sinTheta * sin(phi)
    );

    // 6. Calculate PDF ( Solid Angle )
    // PDF_solidAngle = (PDF_row * PDF_col) / (2 * PI^2 * sin(theta))
    // We catch sinTheta approx 0 to avoid division by zero
    let pixelCount = float(cdf.size.x * cdf.size.y);
    let sinThetaSafe = max(1e-5, sinTheta);
    let pdf = (rowPdf * colPdf * pixelCount) / (2.0 * float.getPi() * float.getPi() * sinThetaSafe);

    // 7. Sample Texture
    // Note: We use the UV we calculated, but we handle rotation manually in direction,
    // so we sample the texture at standard UV coordinates.
    // If your texture rotation is handled by UV offset, adjust 'u' here.
    let sampleUV = float2(u + rotation / (2.0*float.getPi()), v);
    let color = envMap.SampleLevelZero(sampleUV) * intensity;

    return EnvSample(normalize(dir), color, pdf);
}

// Evaluate PDF for MIS (When a BSDF ray hits the background)
float PdfEnvironment(EnvMapCDF cdf, float3 dir, float rotation) {
    // Convert Direction to UV
    let uv = CartesianToSpherical(dir, rotation);

    let x = min(uint(uv.x * cdf.size.x), cdf.size.x - 1);
    let y = min(uint(uv.y * cdf.size.y), cdf.size.y - 1);

    let theta = uv.y * float.getPi();
    let sinTheta = max(1e-5, sin(theta));

    // Look up probabilities directly from CDF
    // P = CDF[i] - CDF[i-1]

    let rowVal = cdf.marginal[y];
    let rowPrev = (y == 0) ? 0.0 : cdf.marginal[y - 1];
    let rowProb = rowVal - rowPrev;

    let colVal = cdf.conditional[y * cdf.size.x + x];
    let colPrev = (x == 0) ? 0.0 : cdf.conditional[y * cdf.size.x + x - 1];
    let colProb = colVal - colPrev;
    let pixelCount = float(cdf.size.x * cdf.size.y);

    return (rowProb * colProb * pixelCount) / (2.0 * float.getPi() * float.getPi() * sinTheta);
}
