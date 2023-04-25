using System;

namespace Nova;

[CRepr, Union]
struct Mat<T, R, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where R : const int
	where C : const int
{
	private typealias _Vec = Vec<T, C>;

	public _Vec[R] rows;
	public T[R * C] values;

	public this(_Vec[R] rows) {
		this.rows = rows;
	}

	public this(T[R * C] values) {
		this.values = values;
	}

	public _Vec this[int index] {
		[Inline] get => rows[index];
		[Inline, Unchecked] get => rows[index];

		[Inline] set mut => rows[index] = value;
		[Inline, Unchecked] set mut => rows[index] = value;
	}

	public ref _Vec this[int index] {
		[Inline] get mut => ref rows[index];
		[Inline, Unchecked] get mut => ref rows[index];
	}

	[Optimize]
	public Self Transpose() {
		Self m = ?;

		for (let i < R) {
			_Vec v = ?;

			for (let j < C) {
				v[j] = (.) this[j][i];
			}

			m[i] = v;
		}

		return m;
	}

	[Optimize]
	public static Self operator*(Self lhs, Self rhs) {
		_Vec[R] m = ?;

		for (let i < R) {
			_Vec v = default;

			for (let j < C) {
				v += lhs[j] * rhs[i][j];
			}

			m[i] = v;
		}

		return .(m);
	}

	[Optimize, Commutable]
	public static Self operator*(Self lhs, T rhs) {
		Self v = ?;

		for (let i < R) {
			v[i] = lhs[i] * rhs;
		}

		return v;
	}
}

extension Mat<T, R, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where R : const int
	where C : const int
	where T : operator explicit float
	where _IsEqual<R, C>.Result : _Yes
{
	[Optimize]
	public static Self Identity() {
		_Vec[R] rows = .();

		for (let i < R) {
			rows[i][i] = (.) 1;
		}

		return .(rows);
	}
}

extension Mat<T, R, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where R : const int
	where C : const int
	where _IsEqual<R, 2>.Result : _Yes
{
	public this(_Vec v1, _Vec v2) {
		this.rows = .(v1, v2);
	}
}

extension Mat<T, R, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where R : const int
	where C : const int
	where _IsEqual<R, 3>.Result : _Yes
{
	public this(_Vec v1, _Vec v2, _Vec v3) {
		this.rows = .(v1, v2, v3);
	}
}

extension Mat<T, R, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where R : const int
	where C : const int
	where T : operator implicit float
	where _IsEqual<R, 4>.Result : _Yes
{
	public this(_Vec v1, _Vec v2, _Vec v3, _Vec v4) {
		this.rows = .(v1, v2, v3, v4);
	}
	
	[Optimize]
	public static Self Ortho(T left, T right, T bottom, T top) {
		return .(_Vec[?] (
			.(T[?] (2 / (right - left), 0, 0, 0)),
			.(T[?] (0, 2 / (top - bottom), 0, 0)),
			.(T[?] (0, 0, -1, 0)),
			.(T[?] (-(right + left) / (right - left), -(top + bottom) / (top - bottom), 0, 1))
		));
	}

	[Optimize]
	public static Self Ortho(T left, T right, T bottom, T top, T near, T far) {
		return .(_Vec[?] (
			.(T[?] (2 / (right - left), 0, 0, 0)),
			.(T[?] (0, 2 / (top - bottom), 0, 0)),
			.(T[?] (0, 0, -1, 0)),
			.(T[?] (-(right + left) / (right - left), -(top + bottom) / (top - bottom), near / (far - near), 1))
		));
	}

	[Optimize]
	public static Self Perspective(T fovy, T aspect, T near, T far) {
		T tanHalfFovy = Tan(DegreesToRadians(fovy) / 2);

		Self m = default;

		// RH_ZO
		m[0][0] = 1 / (aspect * tanHalfFovy);
		m[1][1] = 1 / (tanHalfFovy);
		m[2][2] = far / (near - far);
		m[2][3] = -1;
		m[3][2] = -(far * near) / (far - near);

		// RH_NO
		/*m[0][0] = 1 / (aspect * tanHalfFovy);
		m[1][1] = 1 / (tanHalfFovy);
		m[2][2] = - (far + near) / (far - near);
		m[2][3] = - 1;
		m[3][2] = - (2 * far * near) / (far - near);*/

		return m;
	}

	[Optimize]
	public static Self LookAt(Vec3f eye, Vec3f center, Vec3f up) {
		Vec3f f = (center - eye).Normalized;
		Vec3f s = up.Cross(f).Normalized;
		Vec3f u = f.Cross(s);

		Self m = .Identity();

		m[0][0] = s.x;
		m[1][0] = s.y;
		m[2][0] = s.z;
		m[0][1] = u.x;
		m[1][1] = u.y;
		m[2][1] = u.z;
		m[0][2] = f.x;
		m[1][2] = f.y;
		m[2][2] = f.z;
		m[3][0] = (.) -s.Dot(eye);
		m[3][1] = (.) -u.Dot(eye);
		m[3][2] = (.) -f.Dot(eye);

		return m;
	}

	public Self Translate(Vec<T, 3> v) {
		Self m = this;

		m[3] = m[0] * v[0] + m[1] * v[1] + m[2] * v[2] + m[3];

		return m;
	}

	private static T DegreesToRadians(T deg) where T : var => Math.DegreesToRadians(deg);
	private static T Tan(T deg) where T : var => Math.Tan(deg);
}

extension Mat<T, R, C>
	where T : operator T + T, operator T - T, operator T * T, operator T / T, operator T % T, operator -T
	where bool : operator T < T
	where int : operator T <=> T
	where R : const int
	where C : const int
	where T : operator implicit float
	where _IsLargerEqual<R, 3>.Result : _Yes
{
	public Self Rotate(Vec<T, 3> v, T angle) {
		/*T a = DegreesToRadians(angle);
		T c = Cos(a);
		T s = Sin(a);

		let axis = v.Normalized;
		let temp = (1 - c) * axis;

		Mat<T, 3, 3> rotate = ?;
		rotate[0][0] = c + temp[0] * axis[0];
		rotate[0][1] = temp[0] * axis[1] + s * axis[2];
		rotate[0][2] = temp[0] * axis[2] - s * axis[1];

		rotate[1][0] = temp[1] * axis[0] - s * axis[2];
		rotate[1][1] = c + temp[1] * axis[1];
		rotate[1][2] = temp[1] * axis[2] + s * axis[0];

		rotate[2][0] = temp[2] * axis[0] + s * axis[1];
		rotate[2][1] = temp[2] * axis[1] - s * axis[0];
		rotate[2][2] = c + temp[2] * axis[2];

		Self m = this;

		m[0] = this[0] * rotate[0][0] + this[1] * rotate[0][1] + this[2] * rotate[0][2];
		m[1] = this[0] * rotate[1][0] + this[1] * rotate[1][1] + this[2] * rotate[1][2];
		m[2] = this[0] * rotate[2][0] + this[1] * rotate[2][1] + this[2] * rotate[2][2];
		
		return m;*/
		return this;
	}

	public Self Scale(Vec<T, 3> v) {
		Self m = this;

		m[0] *= v[0];
		m[1] *= v[1];
		m[2] *= v[2];

		return m;
	}

	private static T DegreesToRadians(T deg) where T : var => Math.DegreesToRadians(deg);
	private static T Cos(T deg) where T : var => Math.Cos(deg);
	private static T Sin(T deg) where T : var => Math.Sin(deg);
}

typealias Mat3f = Mat<float, 3, 3>;
typealias Mat4f = Mat<float, 4, 4>;