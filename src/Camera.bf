using System;

namespace Nova;

[CRepr]
struct Camera {
	private Vec4f origin;
	private Vec4f lowerLeftCorner;
	private Vec4f horizontal;
	private Vec4f vertical;

	public this(Vec3f position, Vec3f lookAt, float fov, float aspectRatio) {
		var theta = Math.DegreesToRadians(fov);
		var h = Math.Tan(theta / 2);
		var viewportHeight = 2 * h;
		var viewportWidth = aspectRatio * viewportHeight;

		var w = (position - lookAt).Normalized;
		var u = (Vec3f(0, 1, 0).Cross(w)).Normalized;
		var v = w.Cross(u);

		origin = position;
		horizontal = viewportWidth * u;
		vertical = viewportHeight * v;
		lowerLeftCorner = origin - horizontal / 2 - vertical / 2 - w;
	}
}