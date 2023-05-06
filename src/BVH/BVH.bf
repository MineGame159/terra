using System;
using System.Collections;

using Nova.Math;

namespace Nova.BVH;

class BVH {
	[CRepr]
	public struct Node {
		public AABB4f aabb;
		public uint32 start, count;

		private uint64 _;
	}

	public List<Node> nodes ~ delete _;
	public List<int> primIds ~ delete _;

	public this(int nodeCapacity) {
		this.nodes = new .(nodeCapacity);
	}

	public void ReorderPrimitives<T>(List<T> primitives) {
		if (primIds == null) return;

		List<T> oldPrimitives = new:ScopedAlloc! .(primitives.Count);
		primitives.CopyTo(oldPrimitives);

		for (int i < primitives.Count) {
			primitives[i] = oldPrimitives[primIds[i]];
		}
	}
}