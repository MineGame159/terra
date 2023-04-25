import material;

struct Hit {
    bool didHit;
    
    float t;
    float3 point;
    float3 normal;
    float2 uv;

    Material material;

    __init(float t, float3 point, float3 normal, float2 uv, Material material) {
        this.didHit = true;
        this.t = t;
        this.point = point;
        this.normal = normal;
        this.uv = uv;
        this.material = material;
    }

    static Hit Miss() {
        Hit hit;
        hit.didHit = false;
        return hit;
    }

    static Hit Far() {
        Hit hit;
        hit.didHit = false;
        hit.t = float.maxValue;
        return hit;
    }

    void CompareWith(inout Hit hit) {
        if (didHit && t < hit.t) {
            hit = this;
        }
    }
};