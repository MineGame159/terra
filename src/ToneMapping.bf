using System;

namespace Nova;

enum ToneMappingOperator {
	None,
	Reinhard,
	ReinhardJodie,
	Uncharted2,
	ACES
}

static class ToneMapping {
	// Utils

	private static float Luminance(Vec3f v) {
		return v.Dot(.(0.2126f, 0.7152f, 0.0722f));
	}

	private static Vec3f Mul(Vec3f[3] m, Vec3f v) {
	    float x = m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2];
	    float y = m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2];
	    float z = m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2];
	    return .(x, y, z);
	}

	// Reinhard

	private static Vec3f Reinhard(Vec3f v) {
	    return v / (1 + v);
	}

	// Reinhard Jodie

	private static Vec3f ReinhardJodie(Vec3f v) {
	    float l = Luminance(v);
	    Vec3f tv = v / (1 + v);
		return (v / (1 + l)).Lerp(tv, tv);
	}

	// Uncharted 2

	private static Vec3f Uncharted2TonemapPartial(Vec3f x) {
	    const float A = 0.15f;
	    const float B = 0.50f;
	    const float C = 0.10f;
	    const float D = 0.20f;
	    const float E = 0.02f;
	    const float F = 0.30f;

	    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
	}

	private static Vec3f Uncharted2(Vec3f v) {
	    const float exposure_bias = 2;
	    Vec3f curr = Uncharted2TonemapPartial(v * exposure_bias);

	    Vec3f W = .(11.2f, 11.2f, 11.2f);
	    Vec3f white_scale = .(1, 1, 1) / Uncharted2TonemapPartial(W);
	    return curr * white_scale;
	}

	// ACES

	private const Vec3f[3] ACES_INPUT_MATRIX = .(
		.(0.59719f, 0.35458f, 0.04823f),
		.(0.07600f, 0.90834f, 0.01566f),
		.(0.02840f, 0.13383f, 0.83777f)
	);

	private const Vec3f[3] ACES_OUTPUT_MATRIX = .(
		.( 1.60475f, -0.53108f, -0.07367f),
		.(-0.10208f,  1.10813f, -0.00605f),
		.(-0.00327f, -0.07276f,  1.07602f)
	);

	private static Vec3f RttAndOdtFit(Vec3f v) {
	    Vec3f a = v * (v + 0.0245786f) - 0.000090537f;
	    Vec3f b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
	    return a / b;
	}

	private static Vec3f Aces(Vec3f v) {
		var v;
	    v = Mul(ACES_INPUT_MATRIX, v);
	    v = RttAndOdtFit(v);
	    return Mul(ACES_OUTPUT_MATRIX, v);
	}

	// Tone map

	public static Vec3f ToneMap(Vec3f color, ToneMappingOperator op) {
		switch (op) {
		case .None:				return color;
		case .Reinhard:			return Reinhard(color);
		case .ReinhardJodie:	return ReinhardJodie(color);
		case .Uncharted2:		return Uncharted2(color);
		case .ACES:				return Aces(color);
		}
	}
}