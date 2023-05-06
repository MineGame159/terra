using System;

namespace Nova.Math;

struct Quaternion {
	public float x, y, z, w;

	public this(float x, float y, float z, float w) {
		this.x = x;
		this.y = y;
		this.z = z;
		this.w = w;
	}

	public this(float[4] rotation) : this(rotation[0], rotation[1], rotation[2], rotation[3]) {}

	public this() : this(0, 0, 0, 1) {}

	public float Yaw => (.) Math.RadiansToDegrees(Math.Asin(-2.0 * (x * z - w * y)));
	public float Pitch => (.) Math.RadiansToDegrees(Math.Atan2(2.0 * (y * z + w * x), w * w - x * x - y * y + z * z));

	public Mat4 Matrix { get {
		Mat4 mat = .Identity();

		//Row 1
		mat[0].x = 1.0f - 2.0f * (y * y + z * z);
		mat[0].y = 2.0f * (x * y - w * z);
		mat[0].z = 2.0f * (x * z + w * y);

		//Row 2
		mat[1].x = 2.0f * (x * y + w * z);
		mat[1].y = 1.0f - 2.0f * (x * x + z * z);
		mat[1].z = 2.0f * (y * z - w * x);

		//Row 3
		mat[2].x = 2.0f * (x * z - w * y);
		mat[2].y = 2.0f * (y * z + w * x);
		mat[2].z = 1.0f - 2.0f * (x * x + y * y);

		return mat;
	} }

	public static Self operator *(Self lhs, Self rhs) {
		return .(
			lhs.w * rhs.z + lhs.z * rhs.w + lhs.x * rhs.y - lhs.y * rhs.x,
			lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
			lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
			lhs.w * rhs.y + lhs.y * rhs.w + lhs.z * rhs.x - lhs.x * rhs.z
		);
	}
}