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
        return Hit(t, point, normalize(point - center), float2(0, 0), material);
    }
}

extension Triangle : IPrimitive {
    Hit Intersects(Ray ray) {
        /*let normal = cross(edge1, edge2);
        let ao = ray.origin - vertex0;
        let dao = cross(ao, ray.direction);

        let det = -dot(ray.direction, normal);
        let invDet = 1 / det;

        let t = dot(ao, normal) * invDet;
        let u = dot(edge2, dao) * invDet;
        let v = -dot(edge1, dao) * invDet;
        let w = 1 - u - v;

        Hit hit;

        hit.didHit = det >= 1E-6 && t >= 0 && u >= 0 && v >= 0 && w >= 0;
        hit.t = t;
        hit.point = ray.At(t);
        hit.normal = (u * normals[1] + v * normals[2] + w * normals[0]);
        hit.uv = (u * uvs[1] + v * uvs[2] + w * uvs[0]);
        hit.material = material;

        return hit;*/


        // let h = cross(ray.direction, edge2);
        // let det = dot(edge1, h);
        // let idet = 1.0 / det;

        // let s = ray.origin - vertex0;
        // let u = idet * dot(s, h);

        // let q = cross(s, edge1);
        // let v = idet * dot(ray.direction, q);

        // let t = idet * dot(edge2, q);
        // if (det < 1E-6 || u < 0 || v < 0 || u + v > 1 || t < 0) return Hit.Miss();

        // let w = 1 - u - v;


        let pv = cross(ray.direction, edge2);
        let det = dot(edge1, pv);

        let tv = ray.origin - vertex0.xyz;
        let qv = cross(tv, edge1);

        float4 uvt;
        uvt.x = dot(tv, pv);
        uvt.y = dot(ray.direction, qv);
        uvt.z = dot(edge2, qv);
        uvt.xyz = uvt.xyz / det;
        uvt.w = 1 - uvt.x - uvt.y;

        if (all(uvt >= 1E-4)) {
            let t = uvt.z;
            let bary = uvt.wxy;

            let normal = normalize(normals[0] * bary.x + normals[1] * bary.y + normals[1] * bary.z);
            let uv = uvs[0].xy * bary.x + uvs[1].xy * bary.y + uvs[2].xy * bary.z;

            var hit = Hit(t, ray.At(t), normal, uv, materials[materialIndex]);
            return hit;
        }
        else {
            return Hit.Miss();
        }


        // let h = cross(ray.direction, edge2);
        // let a = dot(edge1, h);

        // if (a > -0.01 && a < 0.01)
        //     return Hit.Miss(); // This ray is parallel to this triangle.

        // let f = 1.0 / a;
        // let s = ray.origin - vertex0;
        // let u = f * dot(s, h);

        // if (u < 0.0 || u > 1.0)
        //     return Hit.Miss();

        // let q = cross(s, edge1);
        // let v = f * dot(ray.direction, q);

        // if (v < 0.0 || u + v > 1.0)
        //     return Hit.Miss();

        // // At this stage we can compute t to find out where the intersection point is on the line.
        // let t = f * dot(edge2, q);

        // if (t > 0.01) // ray intersection
        // {
        //     let w = 1 - u - v;

        //     let normal = normalize(normals[1] * u + normals[2] * v + normals[0] * w);
        //     let uv = uvs[1].xy * u + uvs[2].xy * v + uvs[0].xy * w;

        //     return Hit(t, ray.At(t), normal, uv, materials[materialIndex]);
        // }
        // else // This means that there is a line intersection but not a ray intersection.
        //     return Hit.Miss();


        // let n = cross(edge1, edge2);

        // let c = vertex0 - ray.origin;
        // let r = cross(ray.direction, c);
        // let invDet = 1 / dot(n, ray.direction);

        // let u = dot(r, edge2) * invDet;
        // let v = dot(r, edge1) * invDet;
        // let w = 1 - u - v;

        // if (u >= 0 && v >= 0 && u + v <= 1) {
        //     let t = dot(n, c) * invDet;

        //     if (t >= 0) {
        //         var normal = normalize(u * normals[1] + v * normals[2] + w * normals[0]);
        //         let uv = u * uvs[1].xy + v * uvs[2].xy + w * uvs[0].xy;

        //         //normal = -normal;

        //         return Hit(t, ray.At(t), normal, uv, materials[materialIndex]);
        //     }
        //     else {
        //         return Hit.Miss();
        //     }
        // }
        // else {
        //     return Hit.Miss();
        // }


        // let h = cross(edge1, edge2);
        // let ao = ray.origin - vertex0;
        // let dao = cross(ao, ray.direction);

        // let det = -dot(ray.direction, h);
        // let invDet = 1 / det;

        // let t = dot(ao, h) * invDet;
        // let u = dot(edge2, dao) * invDet;
        // let v = -dot(edge1, dao) * invDet;

        // let w = 1 - u - v;
        // if (abs(det) < 1E-6 || u < 0 || v < 0 || w < 0 || t < 0) return Hit.Miss();

        // var normal = normalize(u * normals[1] + v * normals[2] + w * normals[0]);
        // let uv = u * uvs[1].xy + v * uvs[2].xy + w * uvs[0].xy;

        // return Hit(t, ray.At(t), normal, uv, materials[materialIndex]);
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