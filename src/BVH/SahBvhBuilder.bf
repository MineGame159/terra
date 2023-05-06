using System;
using System.Collections;

using Nova.Math;

namespace Nova.BVH;

abstract class SahBvhBuilder<T> where T : IPrimitive {
	protected Span<T> primitives;

	private BVH bvh;

	public this(Span<T> primitives) {
		this.primitives = primitives;

		this.bvh = new .(primitives.Length);
	}

	protected abstract float FindBestSplitPlane(BVH.Node* node, ref int bestAxis, ref float bestPos);

	public BVH Build() {
		// Root node
		uint32 rootI = AddNode();
		BVH.Node* root = &bvh.nodes[rootI];

		root.start = 0;
		root.count = (.) primitives.Length;

		UpdateNodeBounds(rootI);

		// Subdivide
		Subdivide(rootI);

		// Return
		return bvh;
	}

	private void Subdivide(uint32 nodeI) {
		BVH.Node* node = &bvh.nodes[nodeI];

		// Find best split plane
		int axis = -1;
		float splitPos = 0;
		float splitCost = FindBestSplitPlane(node, ref axis, ref splitPos);

		float nosplitCost = CalculateNodeCost(node);
		if (splitCost >= nosplitCost) return;

		// Sort primitives
		int i = node.start;
		int j = i + node.count - 1;

		while (i <= j) {
			T primitive = primitives[i];

			if (primitive.Center[axis] < splitPos) i++;
			else Swap!(primitives[i], primitives[j--]);
		}

		// Create child nodes
		uint32 leftCount = (.) i - node.start;
		if (leftCount == 0 || leftCount == node.count) return;

		uint32 leftI = AddNode();
		bvh.nodes[leftI].start = node.start;
		bvh.nodes[leftI].count = leftCount;

		uint32 rightI = AddNode();
		bvh.nodes[rightI].start = (.) i;
		bvh.nodes[rightI].count = node.count - leftCount;

		node.start = leftI;
		node.count = 0;

		UpdateNodeBounds(leftI);
		UpdateNodeBounds(rightI);

		Subdivide(leftI);
		Subdivide(rightI);
	}

	private float CalculateNodeCost(BVH.Node* node) {
		float area = GetArea(node.aabb);
		return node.count * area;
	}
	
	private void UpdateNodeBounds(uint32 nodeI) {
	    BVH.Node* node = &bvh.nodes[nodeI];
		AABB3f aabb = .(.MAX, .MIN);

		for (int i < node.count) {
			T primitive = primitives[node.start + i];
			aabb.Grow(primitive.Box);
		}

		node.aabb = aabb;
	}

	private uint32 AddNode() {
		bvh.nodes.Add(.());
		return (.) bvh.nodes.Count - 1;
	}

	protected static float GetArea<C>(AABB<float, C> aabb) where C : const int {
		Vec<float, C> size = aabb.Size;
		return size[0] * size[1] + size[1] * size[2] + size[2] * size[0];
	}

	protected struct Bin {
		public AABB3f aabb;
		public uint32 count;
	}
}