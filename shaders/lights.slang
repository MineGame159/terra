import "utils";

struct LightSample {
    float3 Li;   // Incident Radiance
    float3 dir;  // Direction FROM surface TO light
    float dist;  // Distance to light (for shadow ray)
}

enum LightType : uint {
    Point,
    Spot,
    Directional,
    Rectangle,
    Ellipse,
}

struct Light {
    LightType type;
    float range;
    float innerConeCos;
    float outerConeCos;

    float3 position;
    float3 color;
    float3 direction;

    float2 size;

    float2 _pad;

    LightSample Sample(inout uint rng, float3 position) {
        switch (type) {
            case LightType.Point:
                return SamplePointLight(position);
            case LightType.Spot:
                return SampleSpotLight(position);
            case LightType.Directional:
                return SampleDirectionalLight();
            case LightType.Rectangle:
                return SampleRectangleLight(rng, position);
            case LightType.Ellipse:
                return SampleEllipseLight(rng, position);
            default:
                return LightSample();
        }
    }

    // --- Punctual Lights ---

    LightSample SamplePointLight(float3 position) {
        LightSample sample;

        let offset = this.position - position;
        let distSq = dot(offset, offset);

        sample.dist = sqrt(distSq);
        sample.dir = offset / sample.dist;

        let attenuation = GetRangeAttenuation(distSq, this.range);
        sample.Li = this.color * attenuation;

        return sample;
    }

    LightSample SampleSpotLight(float3 position) {
        LightSample sample;

        let offset = this.position - position;
        let distSq = dot(offset, offset);

        sample.dist = sqrt(distSq);
        sample.dir = offset / sample.dist;

        // A. Range Attenuation
        let rangeAtten = GetRangeAttenuation(distSq, this.range);

        // B. Angular Attenuation (Cone)
        // light.direction points OUT from the source.
        // -rec.dir points INTO the source.
        let actualCos = dot(normalize(this.direction), -sample.dir);

        var angularAtten = 0.0;
        if (actualCos > this.outerConeCos) {
            // Smooth Hermite interpolation between outer and inner cone
            angularAtten = smoothstep(this.outerConeCos, this.innerConeCos, actualCos);
        }

        sample.Li = this.color * rangeAtten * angularAtten;

        return sample;
    }

    LightSample SampleDirectionalLight() {
        LightSample sample;

        // Direction is opposite to emission direction
        sample.dir = normalize(-this.direction);

        // Effectively infinite distance
        sample.dist = 1e9;

        // No falloff for directional lights
        sample.Li = this.color;

        return sample;
    }

    // --- Area Lights ---

    LightSample SampleRectangleLight(inout uint rng, float3 surfPos) {
        LightSample sample;

        // 1. Build Basis
        float3 right, up;
        GetOrthonormalBasis(normalize(this.direction), right, up);

        // 2. Random Point on Rectangle
        // Random(rng) returns [0,1], we map to [-0.5, 0.5]
        let u = Random(rng) - 0.5;
        let v = Random(rng) - 0.5;

        let localPos = (u * this.size.x * right) + (v * this.size.y * up);
        let lightPos = this.position + localPos;

        // 3. Calculate Vector
        let L = lightPos - surfPos;
        let distSq = dot(L, L);
        sample.dist = sqrt(distSq);
        sample.dir = L / sample.dist;

        // 4. Calculate Contribution
        // Since MIS is off, we calculate the full Monte Carlo weight here.
        // Li = Emission * (cosThetaLight * Area) / distSq
        let cosLight = dot(-sample.dir, normalize(this.direction));

        if (cosLight > 0.0) {
            let area = this.size.x * this.size.y;
            let attenuation = GetRangeAttenuation(distSq, this.range); // includes 1/distSq

            sample.Li = this.color * attenuation * cosLight * area;
        } else {
            sample.Li = float3(0.0);
        }

        return sample;
    }

    LightSample SampleEllipseLight(inout uint rng, float3 surfPos) {
        LightSample sample;

        // 1. Build Basis
        float3 right, up;
        GetOrthonormalBasis(normalize(this.direction), right, up);

        // 2. Random Point on Ellipse (Uniform Disk Sampling)
        // sqrt ensures area-uniform distribution
        let r = sqrt(Random(rng));
        let theta = 6.2831853 * Random(rng); // 2 * PI

        // Convert Polar to Cartesian on unit disk
        let diskPos = float2(r * cos(theta), r * sin(theta));

        // Scale by radii (size stores diameters, so multiply by 0.5)
        let localPos = (diskPos.x * this.size.x * 0.5 * right) +
                            (diskPos.y * this.size.y * 0.5 * up);

        let lightPos = this.position + localPos;

        // 3. Calculate Vector
        let L = lightPos - surfPos;
        let distSq = dot(L, L);
        sample.dist = sqrt(distSq);
        sample.dir = L / sample.dist;

        // 4. Calculate Contribution
        let cosLight = dot(-sample.dir, normalize(this.direction));

        if (cosLight > 0.0) {
            // Area = PI * a * b
            let area = float.getPi() * (this.size.x * 0.5) * (this.size.y * 0.5);
            let attenuation = GetRangeAttenuation(distSq, this.range);

            sample.Li = this.color * attenuation * cosLight * area;
        } else {
            sample.Li = float3(0.0);
        }

        return sample;
    }
}

float GetRangeAttenuation(float distSq, float range) {
    // 1. Physical Inverse Square Falloff
    // We max with epsilon to prevent division by zero at the exact light source center
    var attenuation = 1.0 / max(distSq, 1e-4);

    // 2. Finite Range Windowing (KHR_lights_punctual)
    if (range > 0.0) {
        let rangeSq = range * range;

        // The windowing function: square(saturate(1 - (distance^2 / range^2)^2))
        // This creates a smooth falloff to exactly 0.0 at the range limit.
        attenuation *= max(min(1.0 - pow(distSq / rangeSq, 2.0), 1.0), 0.0);
    }

    return attenuation;
}
