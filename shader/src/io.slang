import camera;
import primitives;
import bvh;

struct GlobalData {
    float4 sizeF;
    uint4 sizeI;

    Camera camera;
}

[[vk_push_constant]]
ConstantBuffer<uint> sample;

[[vk_binding(0, 0)]]
ConstantBuffer<GlobalData> globalData;

[[vk_binding(1, 0)]]
StructuredBuffer<BVHNode> sphereBvh;
[[vk_binding(2, 0)]]
StructuredBuffer<Sphere> spherePrimitives;

[[vk_binding(3, 0)]]
StructuredBuffer<BVHNode> triangleBvh;
[[vk_binding(4, 0)]]
StructuredBuffer<Triangle> trianglePrimitives;

[[vk_binding(5, 0)]]
StructuredBuffer<BVHNode> meshInstanceBvh;
[[vk_binding(6, 0)]]
StructuredBuffer<MeshInstance> meshInstancePrimitives;

[[vk_binding(9, 0)]]
RWTexture2D<float4> previous;
[[vk_binding(10, 0)]]
RWTexture2D<float4> output;

float2 GetSize() {
    return globalData.sizeF.xy;
}

uint2 GetSizeInt() {
    return globalData.sizeI.xy;
}

Camera GetCamera() {
    return globalData.camera;
}