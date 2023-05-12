using System;

using Terra.Math;

namespace Terra.BVH;

interface IPrimitive {
	Vec3f Center { get; }

	AABB3f Box { get; }
}