import hit;
import ray;
import material;
import aabb;

interface IPrimitive {
    Hit Intersects(Ray ray);
}

struct Sphere {
    float4 data;
    Material material;

    __init(float3 center, float radius) {
        this.data = float4(center, radius);
    }

    property float3 center { get { return data.xyz; } }
    property float radius { get { return data.w; } }
};

struct Triangle {
    float3 vertex0;
    float3 edge1;
    float3 edge2;

    float3 normals[3];
    float4 uvs[3];

    uint materialIndex;
};

struct MeshInstance {
    float4x4 directionMatrix;
    
    float4x4 invOriginMatrix;
    float4x4 invDirectionMatrix;

    AABB aabb;
    uint rootBvhIndex;
};