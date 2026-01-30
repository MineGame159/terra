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
}

struct Light {
    LightType type;
    float range;
    float innerConeCos;
    float outerConeCos;

    float3 position;
    float3 color;
    float3 direction;

    LightSample Sample(float3 position) {
        switch (type) {
            case LightType.Point:
                return SamplePointLight(position);
            case LightType.Spot:
                return SampleSpotLight(position);
            case LightType.Directional:
                return SampleDirectionalLight();
            default:
                return LightSample();
        }
    }

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
