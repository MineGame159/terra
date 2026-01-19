use glam::{FloatExt, Mat3, Vec3, mat3, vec3};

pub trait ToneMappingOperator {
    fn map(color: Vec3) -> Vec3;
}

// Reinhard Jodie

pub struct ReinhardJodie;

impl ToneMappingOperator for ReinhardJodie {
    fn map(color: Vec3) -> Vec3 {
        fn luminance(v: Vec3) -> f32 {
            v.dot(Vec3::new(0.2126, 0.7152, 0.0722))
        }

        let l = luminance(color);
        let tv = color / (1.0 + color);
        let from = color / (1.0 + l);

        Vec3::new(
            from.x.lerp(tv.x, tv.x),
            from.y.lerp(tv.y, tv.y),
            from.z.lerp(tv.z, tv.z),
        )
    }
}

// Uncharder 2

pub struct Uncharted2;

impl ToneMappingOperator for Uncharted2 {
    fn map(color: Vec3) -> Vec3 {
        fn uncharted2_tonemap_partial(x: Vec3) -> Vec3 {
            const A: f32 = 0.15;
            const B: f32 = 0.50;
            const C: f32 = 0.10;
            const D: f32 = 0.20;
            const E: f32 = 0.02;
            const F: f32 = 0.30;

            ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F
        }

        const EXPOSURE_BIAS: f32 = 2.0;
        const W: Vec3 = vec3(11.2, 11.2, 11.2);

        let curr = uncharted2_tonemap_partial(color * EXPOSURE_BIAS);
        let white_scale = 1.0 / uncharted2_tonemap_partial(W);

        curr * white_scale
    }
}

// Filmic

pub struct Filmic;

impl ToneMappingOperator for Filmic {
    fn map(color: Vec3) -> Vec3 {
        let x = Vec3::ZERO.max(color - 0.004);
        let result = (x * (6.2 * x + 0.5)) / (x * (6.2 * x + 1.7) + 0.06);
        result.powf(2.2)
    }
}

// ACES

pub struct ACES;

impl ToneMappingOperator for ACES {
    fn map(color: Vec3) -> Vec3 {
        fn rtt_and_odt_fit(v: Vec3) -> Vec3 {
            let a = v * (v + 0.0245786) - 0.000090537;
            let b = v * (0.983729 * v + 0.4329510) + 0.238081;
            a / b
        }

        const ACES_INPUT_MATRIX: Mat3 = mat3(
            vec3(0.59719, 0.07600, 0.02840),
            vec3(0.35458, 0.90834, 0.13383),
            vec3(0.04823, 0.01566, 0.83777),
        );

        const ACES_OUTPUT_MATRIX: Mat3 = mat3(
            vec3(1.60475, -0.10208, -0.00327),
            vec3(-0.53108, 1.10813, -0.07276),
            vec3(-0.07367, -0.00605, 1.07602),
        );

        let mut v = ACES_INPUT_MATRIX * color;
        v = rtt_and_odt_fit(v);

        ACES_OUTPUT_MATRIX * v
    }
}

// AgX

pub struct AgX;

impl ToneMappingOperator for AgX {
    fn map(color: Vec3) -> Vec3 {
        fn pow(v: Vec3, p: Vec3) -> Vec3 {
            vec3(v.x.powf(p.x), v.y.powf(p.y), v.z.powf(p.z))
        }

        const LINEAR_REC2020_TO_LINEAR_SRGB: Mat3 = mat3(
            vec3(1.6605, -0.1246, -0.0182),
            vec3(-0.5876, 1.1329, -0.1006),
            vec3(-0.0728, -0.0083, 1.1187),
        );

        const LINEAR_SRGB_TO_LINEAR_REC2020: Mat3 = mat3(
            vec3(0.6274, 0.0691, 0.0164),
            vec3(0.3293, 0.9195, 0.0880),
            vec3(0.0433, 0.0113, 0.8956),
        );

        // Converted to column major from blender: https://github.com/blender/blender/blob/fc08f7491e7eba994d86b610e5ec757f9c62ac81/release/datafiles/colormanagement/config.ocio#L358
        const AG_XINSET_MATRIX: Mat3 = mat3(
            vec3(0.856627153315983, 0.137318972929847, 0.11189821299995),
            vec3(0.0951212405381588, 0.761241990602591, 0.0767994186031903),
            vec3(0.0482516061458583, 0.101439036467562, 0.811302368396859),
        );

        // Converted to column major and inverted from https://github.com/EaryChow/AgX_LUT_Gen/blob/ab7415eca3cbeb14fd55deb1de6d7b2d699a1bb9/AgXBaseRec2020.py#L25
        // https://github.com/google/filament/blob/bac8e58ee7009db4d348875d274daf4dd78a3bd1/filament/src/ToneMapper.cpp#L273-L278
        const AG_XOUTSET_MATRIX: Mat3 = mat3(
            vec3(
                1.1271005818144368,
                -0.1413297634984383,
                -0.14132976349843826,
            ),
            vec3(
                -0.11060664309660323,
                1.157823702216272,
                -0.11060664309660294,
            ),
            vec3(
                -0.016493938717834573,
                -0.016493938717834257,
                1.2519364065950405,
            ),
        );

        const AGX_MIN_EV: f32 = -12.47393;
        const AGX_MAX_EV: f32 = 4.026069;
        const LW: Vec3 = vec3(0.2126, 0.7152, 0.0722);

        const SLOPE: Vec3 = Vec3::ONE;
        const OFFSET: Vec3 = Vec3::ZERO;
        const POWER: Vec3 = Vec3::ONE;
        const SATURATION: f32 = 1.0;

        let mut color = LINEAR_SRGB_TO_LINEAR_REC2020 * color;

        // 1. agx()
        // Input transform (inset)
        color = AG_XINSET_MATRIX * color;

        color = color.max(Vec3::splat(1e-10));

        // Log2 space encoding
        color = color
            .log2()
            .clamp(Vec3::splat(AGX_MIN_EV), Vec3::splat(AGX_MAX_EV));
        color = (color - AGX_MIN_EV) / (AGX_MAX_EV - AGX_MIN_EV);

        color = color.clamp(Vec3::ZERO, Vec3::ONE);

        // Apply sigmoid function approximation
        // Mean error^2: 3.6705141e-06
        let x2 = color * color;
        let x4 = x2 * x2;
        color = 15.5 * x4 * x2 - 40.14 * x4 * color + 31.96 * x4 - 6.868 * x2 * color
            + 0.4298 * x2
            + 0.1191 * color
            - 0.00232;

        // 2. agxLook()
        color = pow(color * SLOPE + OFFSET, POWER);
        let luma = color.dot(LW);
        color = luma + SATURATION * (color - luma);

        // 3. agxEotf()
        // Inverse input transform (outset)
        color = AG_XOUTSET_MATRIX * color;

        // sRGB IEC 61966-2-1 2.2 Exponent Reference EOTF Display
        // NOTE: We're linearizing the output here. Comment/adjust when
        // *not* using a sRGB render target
        color = Vec3::ZERO.max(color).powf(2.2);

        color = LINEAR_REC2020_TO_LINEAR_SRGB * color;

        // Gamut mapping. Simple clamp for now.
        color.clamp(Vec3::ZERO, Vec3::ONE)
    }
}

// PBR Neutral

pub struct PbrNeutral;

impl ToneMappingOperator for PbrNeutral {
    fn map(color: Vec3) -> Vec3 {
        const START_COMPRESSION: f32 = 0.8 - 0.04;
        const DESATURATION: f32 = 0.15;
        const D: f32 = 1.0 - START_COMPRESSION;

        let x = color.min_element();
        let offset = if x < 0.08 { x - 6.25 * x * x } else { 0.04 };
        let mut color = color - offset;

        let peak = color.max_element();
        if peak < START_COMPRESSION {
            return color;
        }

        let new_peak = 1.0 - D * D / (peak + D - START_COMPRESSION);
        color *= new_peak / peak;

        let g = 1.0 - 1.0 / (DESATURATION * (peak - new_peak) + 1.0);
        color.lerp(new_peak * vec3(1.0, 1.0, 1.0), g)
    }
}
