struct Ray {
    float3 origin;
    float3 direction, invDirection;

    __init(float3 origin, float3 direction) {
        this.origin = origin;
        this.direction = direction;
        this.invDirection = 1 / direction;
    }

    float3 At(float t) {
        return origin + direction * t;
    }
};