using System;

namespace Terra.Math;

[Union]
struct Mat4 : IEquatable, IEquatable<Mat4> {
	public Vec4f[4] vecs;
	public float[16] floats;

	public this(Vec4f v1, Vec4f v2, Vec4f v3, Vec4f v4) {
		vecs[0] = v1;
		vecs[1] = v2;
		vecs[2] = v3;
		vecs[3] = v4;
	}

	public this() : this(.ZERO, .ZERO, .ZERO, .ZERO) {}

	public static Mat4 Identity() {
		return .(
			.(1, 0, 0, 0),
			.(0, 1, 0, 0),
			.(0, 0, 1, 0),
			.(0, 0, 0, 1)
		);
	}

	public static Mat4 Ortho(float left, float right, float bottom, float top) {
		return .(
			.(2 / (right - left), 0, 0, 0),
			.(0, 2 / (top - bottom), 0, 0),
			.(0, 0, -1, 0),
			.(-(right + left) / (right - left), -(top + bottom) / (top - bottom), 0, 1)
		);
	}

	public static Mat4 Ortho(float left, float right, float bottom, float top, float near, float far) {
		return .(
			.(2 / (right - left), 0, 0, 0),
			.(0, 2 / (top - bottom), 0, 0),
			.(0, 0, -1, 0),
			.(-(right + left) / (right - left), -(top + bottom) / (top - bottom), near / (far - near), 1)
		);
	}

	public Vec4f this[int index] {
		get => vecs[index];
		set mut => vecs[index] = value;
	}

	public ref Vec4f this[int index] {
		get mut => ref vecs[index];
	}

	public static Mat4 Perspective(float fovy, float aspect, float near, float far) {
		float tanHalfFovy = Math.Tan(Math.DegreesToRadians(fovy) / 2);

		Mat4 m = .();

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

	public static Mat4 LookAt(Vec3f eye, Vec3f center, Vec3f up) {
		Vec3f f = (center - eye).Normalized;
		Vec3f s = up.Cross(f).Normalized;
		Vec3f u = f.Cross(s);

		Mat4 m = .Identity();
		m.vecs[0].x = s.x;
		m.vecs[1].x = s.y;
		m.vecs[2].x = s.z;
		m.vecs[0].y = u.x;
		m.vecs[1].y = u.y;
		m.vecs[2].y = u.z;
		m.vecs[0].z = f.x;
		m.vecs[1].z = f.y;
		m.vecs[2].z = f.z;
		m.vecs[3].x = (.) -s.Dot(eye);
		m.vecs[3].y = (.) -u.Dot(eye);
		m.vecs[3].z = (.) -f.Dot(eye);
		return m;
	}

	public Mat4 Translate(Vec3f v) {
		Mat4 m = this;
		m[3] = m[0] * v[0] + m[1] * v[1] + m[2] * v[2] + m[3];
		return m;
	}

	public Mat4 Rotate(Vec3f v, float angle) {
		float a = Math.DegreesToRadians(angle);
		float c = Math.Cos(a);
		float s = Math.Sin(a);

		Vec3f axis = v.Normalized;
		Vec3f temp = (1 - c) * axis;

		Mat4 Rotate = .();
		Rotate[0][0] = c + temp[0] * axis[0];
		Rotate[0][1] = temp[0] * axis[1] + s * axis[2];
		Rotate[0][2] = temp[0] * axis[2] - s * axis[1];

		Rotate[1][0] = temp[1] * axis[0] - s * axis[2];
		Rotate[1][1] = c + temp[1] * axis[1];
		Rotate[1][2] = temp[1] * axis[2] + s * axis[0];

		Rotate[2][0] = temp[2] * axis[0] + s * axis[1];
		Rotate[2][1] = temp[2] * axis[1] - s * axis[0];
		Rotate[2][2] = c + temp[2] * axis[2];

		return .(
			vecs[0] * Rotate[0][0] + vecs[1] * Rotate[0][1] + vecs[2] * Rotate[0][2],
			vecs[0] * Rotate[1][0] + vecs[1] * Rotate[1][1] + vecs[2] * Rotate[1][2],
			vecs[0] * Rotate[2][0] + vecs[1] * Rotate[2][1] + vecs[2] * Rotate[2][2],
			vecs[3]
		);
	}

	public Mat4 Scale(Vec3f v) {
		return .(
			vecs[0] * v[0],
			vecs[1] * v[1],
			vecs[2] * v[2],
			vecs[3]
		);
	}

	public Mat4 InverseTranspose() {
		float SubFactor00 = this[2][2] * this[3][3] - this[3][2] * this[2][3];
		float SubFactor01 = this[2][1] * this[3][3] - this[3][1] * this[2][3];
		float SubFactor02 = this[2][1] * this[3][2] - this[3][1] * this[2][2];
		float SubFactor03 = this[2][0] * this[3][3] - this[3][0] * this[2][3];
		float SubFactor04 = this[2][0] * this[3][2] - this[3][0] * this[2][2];
		float SubFactor05 = this[2][0] * this[3][1] - this[3][0] * this[2][1];
		float SubFactor06 = this[1][2] * this[3][3] - this[3][2] * this[1][3];
		float SubFactor07 = this[1][1] * this[3][3] - this[3][1] * this[1][3];
		float SubFactor08 = this[1][1] * this[3][2] - this[3][1] * this[1][2];
		float SubFactor09 = this[1][0] * this[3][3] - this[3][0] * this[1][3];
		float SubFactor10 = this[1][0] * this[3][2] - this[3][0] * this[1][2];
		float SubFactor11 = this[1][0] * this[3][1] - this[3][0] * this[1][1];
		float SubFactor12 = this[1][2] * this[2][3] - this[2][2] * this[1][3];
		float SubFactor13 = this[1][1] * this[2][3] - this[2][1] * this[1][3];
		float SubFactor14 = this[1][1] * this[2][2] - this[2][1] * this[1][2];
		float SubFactor15 = this[1][0] * this[2][3] - this[2][0] * this[1][3];
		float SubFactor16 = this[1][0] * this[2][2] - this[2][0] * this[1][2];
		float SubFactor17 = this[1][0] * this[2][1] - this[2][0] * this[1][1];

		Mat4 inverse = ?;
		inverse[0][0] = + (this[1][1] * SubFactor00 - this[1][2] * SubFactor01 + this[1][3] * SubFactor02);
		inverse[0][1] = - (this[1][0] * SubFactor00 - this[1][2] * SubFactor03 + this[1][3] * SubFactor04);
		inverse[0][2] = + (this[1][0] * SubFactor01 - this[1][1] * SubFactor03 + this[1][3] * SubFactor05);
		inverse[0][3] = - (this[1][0] * SubFactor02 - this[1][1] * SubFactor04 + this[1][2] * SubFactor05);

		inverse[1][0] = - (this[0][1] * SubFactor00 - this[0][2] * SubFactor01 + this[0][3] * SubFactor02);
		inverse[1][1] = + (this[0][0] * SubFactor00 - this[0][2] * SubFactor03 + this[0][3] * SubFactor04);
		inverse[1][2] = - (this[0][0] * SubFactor01 - this[0][1] * SubFactor03 + this[0][3] * SubFactor05);
		inverse[1][3] = + (this[0][0] * SubFactor02 - this[0][1] * SubFactor04 + this[0][2] * SubFactor05);

		inverse[2][0] = + (this[0][1] * SubFactor06 - this[0][2] * SubFactor07 + this[0][3] * SubFactor08);
		inverse[2][1] = - (this[0][0] * SubFactor06 - this[0][2] * SubFactor09 + this[0][3] * SubFactor10);
		inverse[2][2] = + (this[0][0] * SubFactor07 - this[0][1] * SubFactor09 + this[0][3] * SubFactor11);
		inverse[2][3] = - (this[0][0] * SubFactor08 - this[0][1] * SubFactor10 + this[0][2] * SubFactor11);

		inverse[3][0] = - (this[0][1] * SubFactor12 - this[0][2] * SubFactor13 + this[0][3] * SubFactor14);
		inverse[3][1] = + (this[0][0] * SubFactor12 - this[0][2] * SubFactor15 + this[0][3] * SubFactor16);
		inverse[3][2] = - (this[0][0] * SubFactor13 - this[0][1] * SubFactor15 + this[0][3] * SubFactor17);
		inverse[3][3] = + (this[0][0] * SubFactor14 - this[0][1] * SubFactor16 + this[0][2] * SubFactor17);

		float determinant = + this[0][0] * inverse[0][0] + this[0][1] * inverse[0][1] + this[0][2] * inverse[0][2] + this[0][3] * inverse[0][3];
		inverse /= determinant;

		return inverse;
	}

	public Mat4 Transpose() {
		Mat4 Result = this;

		Result[0][0] = this[0][0];
		Result[0][1] = this[1][0];
		Result[0][2] = this[2][0];
		Result[0][3] = this[3][0];

		Result[1][0] = this[0][1];
		Result[1][1] = this[1][1];
		Result[1][2] = this[2][1];
		Result[1][3] = this[3][1];

		Result[2][0] = this[0][2];
		Result[2][1] = this[1][2];
		Result[2][2] = this[2][2];
		Result[2][3] = this[3][2];

		Result[3][0] = this[0][3];
		Result[3][1] = this[1][3];
		Result[3][2] = this[2][3];
		Result[3][3] = this[3][3];

		return Result;
	}

	public Mat4 Inverse() {
		float Coef00 = this[2][2] * this[3][3] - this[3][2] * this[2][3];
		float Coef02 = this[1][2] * this[3][3] - this[3][2] * this[1][3];
		float Coef03 = this[1][2] * this[2][3] - this[2][2] * this[1][3];

		float Coef04 = this[2][1] * this[3][3] - this[3][1] * this[2][3];
		float Coef06 = this[1][1] * this[3][3] - this[3][1] * this[1][3];
		float Coef07 = this[1][1] * this[2][3] - this[2][1] * this[1][3];

		float Coef08 = this[2][1] * this[3][2] - this[3][1] * this[2][2];
		float Coef10 = this[1][1] * this[3][2] - this[3][1] * this[1][2];
		float Coef11 = this[1][1] * this[2][2] - this[2][1] * this[1][2];

		float Coef12 = this[2][0] * this[3][3] - this[3][0] * this[2][3];
		float Coef14 = this[1][0] * this[3][3] - this[3][0] * this[1][3];
		float Coef15 = this[1][0] * this[2][3] - this[2][0] * this[1][3];

		float Coef16 = this[2][0] * this[3][2] - this[3][0] * this[2][2];
		float Coef18 = this[1][0] * this[3][2] - this[3][0] * this[1][2];
		float Coef19 = this[1][0] * this[2][2] - this[2][0] * this[1][2];

		float Coef20 = this[2][0] * this[3][1] - this[3][0] * this[2][1];
		float Coef22 = this[1][0] * this[3][1] - this[3][0] * this[1][1];
		float Coef23 = this[1][0] * this[2][1] - this[2][0] * this[1][1];

		Vec4f Fac0 = .(Coef00, Coef00, Coef02, Coef03);
		Vec4f Fac1 = .(Coef04, Coef04, Coef06, Coef07);
		Vec4f Fac2 = .(Coef08, Coef08, Coef10, Coef11);
		Vec4f Fac3 = .(Coef12, Coef12, Coef14, Coef15);
		Vec4f Fac4 = .(Coef16, Coef16, Coef18, Coef19);
		Vec4f Fac5 = .(Coef20, Coef20, Coef22, Coef23);

		Vec4f Vec0 = .(this[1][0], this[0][0], this[0][0], this[0][0]);
		Vec4f Vec1 = .(this[1][1], this[0][1], this[0][1], this[0][1]);
		Vec4f Vec2 = .(this[1][2], this[0][2], this[0][2], this[0][2]);
		Vec4f Vec3 = .(this[1][3], this[0][3], this[0][3], this[0][3]);

		Vec4f Inv0 = Vec1 * Fac0 - Vec2 * Fac1 + Vec3 * Fac2;
		Vec4f Inv1 = Vec0 * Fac0 - Vec2 * Fac3 + Vec3 * Fac4;
		Vec4f Inv2 = Vec0 * Fac1 - Vec1 * Fac3 + Vec3 * Fac5;
		Vec4f Inv3 = Vec0 * Fac2 - Vec1 * Fac4 + Vec2 * Fac5;

		Vec4f SignA = .(+1, -1, +1, -1);
		Vec4f SignB = .(-1, +1, -1, +1);
		Mat4 Inverse = .(Inv0 * SignA, Inv1 * SignB, Inv2 * SignA, Inv3 * SignB);

		Vec4f Row0 = .(Inverse[0][0], Inverse[1][0], Inverse[2][0], Inverse[3][0]);

		Vec4f Dot0 = this[0] * Row0;
		float Dot1 = (Dot0.x + Dot0.y) + (Dot0.z + Dot0.w);

		float OneOverDeterminant = 1f / Dot1;

		return Inverse * OneOverDeterminant;
	}

	public bool Equals(Object o) => (o is Mat4) ? Equals((Mat4) o) : false;
	public bool Equals(Mat4 m) => vecs[0] == m.vecs[0] && vecs[1] == m.vecs[1] && vecs[2] == m.vecs[2] && vecs[3] == m.vecs[3];

	//public int GetHashCode() => vecs[0].GetHashCode() + vecs[1].GetHashCode() + vecs[2].GetHashCode() + vecs[3].GetHashCode();

	public static Self operator*(Self m1, Self m2) {
		Vec4f SrcA0 = m1[0];
		Vec4f SrcA1 = m1[1];
		Vec4f SrcA2 = m1[2];
		Vec4f SrcA3 = m1[3];

		Vec4f SrcB0 = m2[0];
		Vec4f SrcB1 = m2[1];
		Vec4f SrcB2 = m2[2];
		Vec4f SrcB3 = m2[3];

		return .(
			SrcA0 * SrcB0[0] + SrcA1 * SrcB0[1] + SrcA2 * SrcB0[2] + SrcA3 * SrcB0[3],
			SrcA0 * SrcB1[0] + SrcA1 * SrcB1[1] + SrcA2 * SrcB1[2] + SrcA3 * SrcB1[3],
			SrcA0 * SrcB2[0] + SrcA1 * SrcB2[1] + SrcA2 * SrcB2[2] + SrcA3 * SrcB2[3],
			SrcA0 * SrcB3[0] + SrcA1 * SrcB3[1] + SrcA2 * SrcB3[2] + SrcA3 * SrcB3[3]
		);
	}

	public static Self operator*(Self lhs, float rhs) {
		Self mat = lhs;

		mat[0] *= rhs;
		mat[1] *= rhs;
		mat[2] *= rhs;
		mat[3] *= rhs;

		return mat;
	}

	public static Vec4f operator*(Self lhs, Vec4f rhs) {
		let mov0 = rhs[0];
		let mov1 = rhs[1];
		let mul0 = lhs[0] * mov0;
		let mul1 = lhs[1] * mov1;
		let add0 = mul0 + mul1;
		let mov2 = rhs[2];
		let mov3 = rhs[3];
		let mul2 = lhs[2] * mov2;
		let mul3 = lhs[3] * mov3;
		let add1 = mul2 + mul3;
		let add2 = add0 + add1;
		return add2;
	}

	public static Mat4 operator/(Self lhs, float rhs) {
		Self mat = lhs;

		mat[0] /= rhs;
		mat[1] /= rhs;
		mat[2] /= rhs;
		mat[3] /= rhs;

		return mat;
	}
}