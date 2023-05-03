using System;
using System.Collections;

namespace Nova.BVH;

class SimpleSahBvhBuilder<T> : SahBvhBuilder<T> where T : IPrimitive {
	public this(List<T> primitives) : base(primitives) {}

	protected override float FindBestSplitPlane(BVH.Node* node, ref int bestAxis, ref float bestPos) {
		float bestCost = float.MaxValue;

		for (int axis < 3) {
			for (uint32 i < node.count) {
				T primitive = primitives[node.start + i];

				float candidatePos = primitive.Center[axis];
				float cost = EvaluateSAH(node, axis, candidatePos);

				if (cost < bestCost) {
					bestCost = cost;
					bestAxis = axis;
					bestPos = candidatePos;
				}
			}
		}

		return bestCost;
	}

	private float EvaluateSAH(BVH.Node* node, int axis, float pos) {
		AABB3f left = .(.MAX, .MIN);
		AABB3f right = .(.MAX, .MIN);

		int leftCount = 0;
		int rightCount = 0;

		for (uint32 i < node.count) {
			T primitive = primitives[node.start + i];

			if (primitive.Center[axis] < pos) {
				left.Grow(primitive.Box);
				leftCount++;
			}
			else {
				right.Grow(primitive.Box);
				rightCount++;
			}
		}

		float cost = leftCount * GetArea(left) + rightCount * GetArea(right);
		return cost > 0 ? cost : float.MaxValue;
	}
}