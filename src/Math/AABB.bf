using System;

namespace Nova;

[CRepr]
struct AABB<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
{
	private typealias _Vec = Vec<T, C>;

	public _Vec min;
	public _Vec max;

	public this(_Vec min, _Vec max) {
		this.min = min;
		this.max = max;
	}

	public _Vec Size => max - min;

	public void Grow(_Vec vec) mut {
		min = min.Min(vec);
		max = max.Max(vec);
	}

	public Self Surrounding(Self aabb) => .(min.Min(aabb.min), max.Max(aabb.max));
}

typealias AABB2f = AABB<float, 2>;
typealias AABB3f = AABB<float, 3>;
typealias AABB4f = AABB<float, 4>;

typealias AABB2d = AABB<double, 2>;
typealias AABB3d = AABB<double, 3>;
typealias AABB4d = AABB<double, 4>;