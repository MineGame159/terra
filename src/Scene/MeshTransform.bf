using System;

using Nova.Math;

namespace Nova.Scene;

struct MeshTransform {
	public Mat4 originMatrix;
	public Mat4 directionMatrix;

	public this(Vec3f position, Quaternion rotation, Vec3f scale) {
		this.originMatrix = (Mat4.Identity().Translate(position) * rotation.Matrix.Transpose()).Scale(scale);
		this.directionMatrix = (Mat4.Identity() * rotation.Matrix.Transpose()).Scale(scale);
	}
}