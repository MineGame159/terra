using System;
using System.Collections;

namespace Nova;

static class BVH {
	public enum Quality : uint32 {
		Low,
		Medium,
		High
	}

	[CRepr]
	public struct Config {
		public Quality quality = .High;
	}

	[CRepr]
	public struct Node {
		public AABB4f aabb;
		public uint32 start, count;

		private uint64 _;
	}

	[CRepr]
	public struct Result {
		public Node* nodes;
		public uint32 nodeCount;

		public uint32* primitiveIds;
	}

	[CLink]
	private static extern Result bvh_build(Config config, AABB3f* primitiveAabbs, Vec3f* primitiveCenters, uint32 primitiveCount);

	[CLink]
	private static extern void bvh_free(Result result);

	public static Result Build<T>(Config config, List<T> primitives) where T : IPrimitive {
		// Generate AABBs and centers for primitives
		List<AABB3f> aabbs = new:ScopedAlloc! .(primitives.Count);
		List<Vec3f> centers = new:ScopedAlloc! .(primitives.Count);

		for (int i < primitives.Count) {
			T primitive = primitives[i];

			aabbs.Add(primitive.Box);
			centers.Add(primitive.Center);
		}

		// Build BVH
		Result result = bvh_build(config, aabbs.Ptr, centers.Ptr, (.) primitives.Count);

		// Reorder primitives
		List<T> oldPrimitives = new:ScopedAlloc! .(primitives.Count);
		primitives.CopyTo(oldPrimitives);

		for (int i < primitives.Count) {
			primitives[i] = oldPrimitives[result.primitiveIds[i]];
		}

		// Return
		return result;
	}

	public static void Free(Result result) => bvh_free(result);
}