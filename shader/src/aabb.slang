import ray;

struct AABB {
    float3 _min;
    float3 _max;

    bool Intersects(Ray ray) {
        let min1 = (_min - ray.origin) * ray.invDirection;
        let max1 = (_max - ray.origin) * ray.invDirection;

        let min2 = min(min1, max1);
        let max2 = max(min1, max1);

        //let min3 = max(tMin, max(min2.x, max(min2.y, min2.z)));
        //let max3 = min(tMax, min(max2.x, min(max2.y, max2.z)));

        let min3 = max(min2.x, max(min2.y, min2.z));
        let max3 = min(max2.x, min(max2.y, max2.z));

        // return max3 >= min3 ? min3 : 1e30f;
        return max3 >= min3;
    }
};