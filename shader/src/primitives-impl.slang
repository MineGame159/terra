import primitives;
import hit;
import ray;
import bvh;
import io;
import utils;
import material;

extension Sphere : IPrimitive {
    Hit Intersects(Ray ray) {
        let offset = ray.origin - center;

        let a = dot(ray.direction, ray.direction);
        let b = 2 * dot(offset, ray.direction);
        let c = dot(offset, offset) - radius * radius;

        let discriminant = b * b - 4 * a * c;
        if (discriminant < 0) return Hit.Miss();

        let t = (-b - sqrt(discriminant)) / (2 * a);
        if (t < 0) return Hit.Miss();

        let point = ray.At(t);
        return Hit(t, point, normalize(point - center), float2(0, 0), materials[materialIndex]);
    }
}

extension Triangle : IPrimitive {
    Hit Intersects(Ray ray) {
        // Calculate intersection
        let pvec = cross(ray.direction, edge2);
        let det = dot(edge1, pvec);
        let invDet = 1 / det;

        let tvec = ray.origin - vertex0;
        let u = dot(tvec, pvec) * invDet;

        let qvec = cross(tvec, edge1);
        let v = dot(ray.direction, qvec) * invDet;

        let w = 1 - u - v;
        let t = dot(edge2, qvec) * invDet;

        // Check for miss
        if (u < 0 || u > 1 || v < 0 || w < 0 || t <= 1E-4)
            return Hit.Miss();

        // Calculate hit info
        let normal = normalize(normals[0] * w + normals[1] * u + normals[1] * v);
        let uv = uvs[0].xy * w + uvs[1].xy * u + uvs[2].xy * v;

        return Hit(t, ray.At(t), normal, uv, materials[materialIndex]);
    }
}

extension MeshInstance : IPrimitive {
    Hit Intersects(Ray ray) {
        let origin = mul(invOriginMatrix, float4(ray.origin, 1)).xyz;
        let direction = mul(invDirectionMatrix, float4(ray.direction, 0)).xyz;

        let newRay = Ray(origin, direction);
        var hit = IntersectsBVH(triangleBvh, trianglePrimitives, newRay, rootBvhIndex);

        hit.point = ray.At(hit.t);
        hit.normal = normalize(mul(directionMatrix, float4(hit.normal, 0)).xyz);

        return hit;
    }
}