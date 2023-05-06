using System;

using Nova.Math;

namespace Nova.BVH;

interface IPrimitive {
	Vec3f Center { get; }

	AABB3f Box { get; }
}