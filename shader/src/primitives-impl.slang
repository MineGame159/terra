import primitives;
import hit;
import ray;
import bvh;
import io;
import utils;
import material;

extension Sphere : IBLASPrimitve {
    bool Intersects(Ray ray, inout float4 data) {
        // Calculate intersection
        let offset = ray.origin - center;

        let a = dot(ray.direction, ray.direction);
        let b = 2 * dot(offset, ray.direction);
        let c = dot(offset, offset) - radius * radius;

        let discriminant = b * b - 4 * a * c;
        if (discriminant < 0) return false;

        let t = (-b - sqrt(discriminant)) / (2 * a);
        if (t < 0) return false;

        // Return
        if (t < data.x) {
            data.x = t;
            return true;
        }

        return false;
    }

    Hit GetHit(Ray ray, float4 data) {
        let point = ray.At(data.x);
        return Hit(data.x, point, normalize(point - center), float2(0, 0), materials[materialIndex]);
    }
}

extension Triangle : IBLASPrimitve {
    bool Intersects(Ray ray, inout float4 data) {
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

        // Return
        if (u >= 0 && u <= 1 && v >= 0 && w >= 0 && t > 1E-4 && t < data.w) {
            data = float4(w, u, v, t);
            return true;
        }

        return false;
    }

    Hit GetHit(Ray ray, float4 data) {
        let normal = normalize(normals[0] * data.x + normals[1] * data.y + normals[1] * data.z);
        let uv = uvs[0].xy * data.x + uvs[1].xy * data.y + uvs[2].xy * data.z;

        return Hit(data.w, ray.At(data.w), normal, uv, materials[materialIndex]);
    }
}

extension MeshInstance : ITLASPrimitive {
    Hit Intersects(Ray ray) {
        let origin = mul(invOriginMatrix, float4(ray.origin, 1)).xyz;
        let direction = mul(invDirectionMatrix, float4(ray.direction, 0)).xyz;

        let newRay = Ray(origin, direction);
        var hit = IntersectsBLAS(triangleBvh, trianglePrimitives, newRay, rootBvhIndex);

        hit.point = ray.At(hit.t);
        hit.normal = normalize(mul(directionMatrix, float4(hit.normal, 0)).xyz);

        return hit;
    }
}