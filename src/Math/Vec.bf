using System;

namespace Nova;

#region Base struct

[CRepr]
struct Vec<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
{
	public static Self ZERO = Self(default);

	private T[C] values;

	[Inline]
	public this(T[C] values) {
		this.values = values;
	}
	
	[Inline]
	public this(T x) {
		for (let i < C) {
			values[i] = x;
		}
	}

	public T this[int index] {
		[Inline] get => values[index];
		[Inline, Unchecked] get => values[index];

		[Inline] set mut => values[index] = value;
		[Inline, Unchecked] set mut => values[index] = value;
	}

	public ref T this[int index] {
		[Inline] get mut => ref values[index];
		[Inline, Unchecked] get mut => ref values[index];
	}

	public int LargestAxis { [Optimize] get {
		int axis = 0;

		for (let i < C) {
			if (values[i] > values[axis])
				axis = i;
		}

		return axis;
	} }

	public int SmallestAxis { [Optimize] get {
		int axis = 0;

		for (let i < C) {
			if (values[i] < values[axis])
				axis = i;
		}

		return axis;
	} }

	[Optimize]
	public Self Min(Self v) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = Min(this[i], v[i]);
		}

		return .(values);
	}

	[Optimize]
	public Self Max(Self v) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = Max(this[i], v[i]);
		}

		return .(values);
	}

	[Optimize]
	public Self Clamp(T min, T max) {
		T[C] values = ?;
		
		for (let i < C) {
			values[i] = Math.[Inline]Clamp(this[i], min, max);
		}

		return .(values);
	}

	private static T Min(T a, T b) => a < b ? a : b;
	private static T Max(T a, T b) => a < b ? b : a;

	public override void ToString(String str) {
		for (let i < C) {
			str.AppendF(i > 0 ? ", {}" : "{}", this[i]);
		}
	}

	[Optimize]
	public static Self operator-(Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = -rhs[i];
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator+(Self lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] + rhs[i];
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator-(Self lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] - rhs[i];
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator*(Self lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] * rhs[i];
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator/(Self lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] / rhs[i];
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator%(Self lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] % rhs[i];
		}

		return .(values);
	}
	
	[Optimize, Commutable]
	public static Self operator+(Self lhs, T rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] + rhs;
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator-(Self lhs, T rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] - rhs;
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator-(T lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs - rhs[i];
		}

		return .(values);
	}
	
	[Optimize, Commutable]
	public static Self operator*(Self lhs, T rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] * rhs;
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator/(Self lhs, T rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] / rhs;
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator/(T lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs / rhs[i];
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator%(Self lhs, T rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs[i] % rhs;
		}

		return .(values);
	}
	
	[Optimize]
	public static Self operator%(T lhs, Self rhs) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = lhs % rhs[i];
		}

		return .(values);
	}
}

#endregion

#region Type based extensions

extension Vec<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T
	where T : IFloating, operator explicit float
	where C : const int
{
	public T LengthSquared => [Inline]Dot(this);
	public T Length => Sqrt(LengthSquared);

	public Self Normalized => this / Length;

	public Self Absolute { [Optimize] get {
		T[C] values = ?;

		for (let i < C) {
			values[i] = Abs(this[i]);
		}

		return .(values);
	} }
	
	[Optimize]
	public T Dot(Self v) {
		T dot = (.) 0;

		for (let i < C) {
			dot += this[i] * v[i];
		}

		return dot;
	}

	[Optimize]
	public Self Pow(Self v) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = Pow(this[i], v[i]);
		}

		return .(values);
	}

	[Optimize]
	public Self Pow(T v) => [Inline]Pow(Self(v));

	[Optimize]
	public Self Lerp(Self to, Self s) {
		T[C] values = ?;

		for (let i < C) {
			values[i] = Lerp(this[i], to[i], s[i]);
		}

		return .(values);
	}

	[Optimize]
	public Self Lerp(Self to, T s) => [Inline]Lerp(to, Self(s));

	public Self Reflect(Self vec) => this - (T) 2 * Dot(vec) * vec;

	private static V Sqrt<V>(V v) where V : var => Math.Sqrt(v);
	private static V Abs<V>(V v) where V : var => Math.Abs(v);
	private static V Pow<V>(V v, V c) where V : var => Math.Pow(v, c);
	private static T Lerp(T from, T to, T s) => from + (to - from) * s;
}

extension Vec<T, C> where T : Float {
	public static Self MIN = .((.) T.MinValue);
	public static Self MAX = .((.) T.MaxValue);
}

extension Vec<T, C> where T : Double {
	public static Self MIN = .((.) T.MinValue);
	public static Self MAX = .((.) T.MaxValue);
}

#endregion

#region Count based extensions

extension Vec<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
	where _IsEqual<C, 2>.Result : _Yes
{
	[Inline]
	public this(T x, T y) {
		this.values = .(x, y);
	}

	public T x {
		[Inline] get => values[0];
		[Inline] set mut => values[0] = value;
	}
	public T y {
		[Inline] get => values[1];
		[Inline] set mut => values[1] = value;
	}

	public static implicit operator Vec<T, 3>(Self v) => .(v[0], v[1], default);
	public static implicit operator Vec<T, 4>(Self v) => .(v[0], v[1], default, default);
}

extension Vec<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
	where _IsEqual<C, 3>.Result : _Yes
{
	[Inline]
	public this(T x, T y, T z) {
		this.values = .(x, y, z);
	}
	
	public T x {
		[Inline] get => values[0];
		[Inline] set mut => values[0] = value;
	}
	public T y {
		[Inline] get => values[1];
		[Inline] set mut => values[1] = value;
	}
	public T z {
		[Inline] get => values[2];
		[Inline] set mut => values[2] = value;
	}
	
	[Optimize]
	public Self Cross(Self v) => .(this[1] * v[2] - this[2] * v[1], this[2] * v[0] - this[0] * v[2], this[0] * v[1] - this[1] * v[0]);

	public static explicit operator Vec<T, 2>(Self v) => .(v[0], v[1]);

	public static implicit operator Vec<T, 4>(Self v) => .(v[0], v[1], v[2], default);
}

extension Vec<T, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where C : const int
	where _IsEqual<C, 4>.Result : _Yes
{
	[Inline]
	public this(T x, T y, T z, T w) {
		this.values = .(x, y, z, w);
	}
	
	public T x {
		[Inline] get => values[0];
		[Inline] set mut => values[0] = value;
	}
	public T y {
		[Inline] get => values[1];
		[Inline] set mut => values[1] = value;
	}
	public T z {
		[Inline] get => values[2];
		[Inline] set mut => values[2] = value;
	}
	public T w {
		[Inline] get => values[3];
		[Inline] set mut => values[3] = value;
	}

	public static explicit operator Vec<T, 2>(Self v) => .(v[0], v[1]);
	public static explicit operator Vec<T, 3>(Self v) => .(v[0], v[1], v[2]);
}

#endregion

#region Type aliases

typealias Vec2f = Vec<float, 2>;
typealias Vec3f = Vec<float, 3>;
typealias Vec4f = Vec<float, 4>;

typealias Vec2d = Vec<double, 2>;
typealias Vec3d = Vec<double, 3>;
typealias Vec4d = Vec<double, 4>;

#endregion