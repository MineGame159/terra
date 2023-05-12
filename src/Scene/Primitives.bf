using System;

using Terra.BVH;
using Terra.Math;

namespace Terra.Scene;

[CRepr]
struct Sphere : this(Vec3f center, float radius, uint32[4] data), IPrimitive {
	public Vec3f Center => center;

	public AABB3f Box => .(center - radius, center + radius);
}

[CRepr]
struct Triangle : this(Vec4f vertex0, Vec4f edge1, Vec4f edge2, Vec4f[3] normals, Vec4f[3] uvs, uint32[4] data), IPrimitive {
	public Vec3f Center => (.) (vertex0 + (vertex0 + edge1) + (vertex0 + edge2)) / 3;

	public AABB3f Box { get {
		Vec4f min = .MAX;
		Vec4f max = .MIN;

		mixin Process(Vec4f vertex) {
			min = min.Min(vertex);
			max = max.Max(vertex);
		}

		Process!(vertex0);
		Process!(vertex0 + edge1);
		Process!(vertex0 + edge2);

		return .((.) min, (.) max);
	} }
}

[CRepr]
struct MeshInstance : IPrimitive {
	public Mat4 directionMatrix;

	public Mat4 invOriginMatrix;
	public Mat4 invDirectionMatrix;
	
	private AABB4f aabb;

	public uint32 rootBvhIndex;
	private uint32 _1, _2, _3;

	public this(Mat4 originMatrix, Mat4 directionMatrix, AABB4f aabb, uint32 rootBvhIndex) {
		this.directionMatrix = directionMatrix;
		this.invOriginMatrix = originMatrix.Inverse();
		this.invDirectionMatrix = directionMatrix.Inverse();
		this.aabb = aabb;
		this.rootBvhIndex = rootBvhIndex;

		this._1 = ?;
		this._2 = ?;
		this._3 = ?;
	}

	public Vec3f Center => (.) -invOriginMatrix[3];

	public AABB3f Box => .((.) aabb.min, (.) aabb.max);
}