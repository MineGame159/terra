using System;
using System.Collections;

using Terra.Math;

namespace Terra.BVH;

class BinnedSahBvhBuilder<T> : SahBvhBuilder<T> where T : IPrimitive {
	public const int BINS = 16;

	public this(Span<T> primitives) : base(primitives) {}

	protected override float FindBestSplitPlane(BVH.Node* node, ref int bestAxis, ref float bestPos) {
		float bestCost = float.MaxValue;

		for (int axis < 3) {
			// Find minimum and maximum values for the axis
			float min = float.MaxValue;
			float max = float.MinValue;

			for (uint32 i < node.count) {
				float center = primitives[node.start + i].Center[axis];

				min = Utils.Min(min, center);
				max = Utils.Max(max, center);
			}

			if (min == max) continue;

			// Populate bins
			Self.Bin[BINS] bins = default;
			float scale = BINS / (max - min);

			for (uint32 i < BINS) {
				bins[i].aabb = .(.MAX, .MIN);
			}

			for (uint32 i < node.count) {
				T primitive = primitives[node.start + i];
				float center = primitive.Center[axis];

				int binI = Utils.Min(BINS - 1, (.) ((center - min) * scale));
				Self.Bin* bin = &bins[binI];

				bin.aabb.Grow(primitive.Box);
				bin.count++;
			}

			// Calculate data for the planes between the bins
			float[BINS - 1] leftArea = default;
			float[BINS - 1] rightArea = default;

			int[BINS - 1] leftCount = default;
			int[BINS - 1] rightCount = default;

			AABB3f leftBox = .(.MAX, .MIN);
			AABB3f rightBox = .(.MAX, .MIN);

			int leftSum = 0;
			int rightSum = 0;

			for (int i < BINS - 1) {
				leftSum += bins[i].count;
				leftCount[i] = leftSum;
				leftBox.Grow(bins[i].aabb);
				leftArea[i] = GetArea(leftBox);

				rightSum += bins[BINS - 1 - i].count;
				rightCount[BINS - 2 - i] = rightSum;
				rightBox.Grow(bins[BINS - 1 - i].aabb);
				rightArea[BINS - 2 - i] = GetArea(rightBox);
			}

			// Calculate SAH cost for the planes
			scale = (max - min) / BINS;

			for (uint i < BINS - 1) {
				float planeCost = leftCount[i] * leftArea[i] + rightCount[i] * rightArea[i];

				if (planeCost < bestCost) {
					bestCost = planeCost;
					bestAxis = axis;
					bestPos = min + scale * (i + 1);
				}
			}
		}

		return bestCost;
	}
}