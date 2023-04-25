import ray;
import hit;
import primitives;
import aabb;

struct BVHNode {
    AABB aabb;

    uint start;
    uint count;
};

Hit IntersectsBVH<T : IPrimitive>(StructuredBuffer<BVHNode> nodes, StructuredBuffer<T> primitives, Ray ray, uint root) {
    if (!nodes[root].aabb.Intersects(ray))
        return Hit.Miss();
    
    var closestHit = Hit.Far();
    closestHit.t = float.maxValue;

    uint stack[64];
    stack[0] = root;

    uint stackI = 1;

    while (stackI > 0) {
        let node = nodes[stack[--stackI]];

        if (node.count > 0) {
            for (uint i = 0; i < node.count; i++) {
                let primitive = primitives[node.start + i];
                primitive.Intersects(ray).CompareWith(closestHit);
            }
        }
        else {
            let nodeLeft = nodes[node.start];
            let nodeRight = nodes[node.start + 1];

            let hitLeft = nodeLeft.aabb.Intersects(ray);
            let hitRight = nodeRight.aabb.Intersects(ray);

            if (hitLeft) stack[stackI++] = node.start;
            if (hitRight) stack[stackI++] = node.start + 1;
        }
    }

    return closestHit;
}