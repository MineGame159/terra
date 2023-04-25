import ray;

struct Camera {
    float4 origin;
    float4 lowerLeftCorner;
    float4 horizontal;
    float4 vertical;

    Ray GetRay(float2 uv) {
        return Ray(origin.xyz, lowerLeftCorner.xyz + uv.x * horizontal.xyz + uv.y * vertical.xyz - origin.xyz);
    }
};