using System;

namespace Nova.Math;

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

	public void Grow(Self aabb) mut {
		min = min.Min(aabb.min);
		max = max.Max(aabb.max);
	}

	public Self Surrounding(Self aabb) => .(min.Min(aabb.min), max.Max(aabb.max));
}

extension AABB<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
	where _IsEqual<C, 2>.Result : _Yes
{
	public static implicit operator AABB<T, 3>(Self aabb) => .(.(aabb.min[0], aabb.min[1], default), .(aabb.max[0], aabb.max[1], default));
}

extension AABB<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
	where _IsEqual<C, 3>.Result : _Yes
{
	public static implicit operator AABB<T, 4>(Self aabb) => .(.(aabb.min[0], aabb.min[1], aabb.min[2], default), .(aabb.max[0], aabb.max[1], aabb.max[2], default));

	public static explicit operator AABB<T, 2>(Self aabb) => .(.(aabb.min[0], aabb.min[1]), .(aabb.max[0], aabb.max[1]));
}

extension AABB<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
	where _IsEqual<C, 4>.Result : _Yes
{
	public static explicit operator AABB<T, 3>(Self aabb) => .(.(aabb.min[0], aabb.min[1], aabb.min[2]), .(aabb.max[0], aabb.max[1], aabb.max[2]));
}

typealias AABB2f = AABB<float, 2>;
typealias AABB3f = AABB<float, 3>;
typealias AABB4f = AABB<float, 4>;

typealias AABB2d = AABB<double, 2>;
typealias AABB3d = AABB<double, 3>;
typealias AABB4d = AABB<double, 4>;