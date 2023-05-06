using System;

using Nova.Gpu;
using Nova.Math;

namespace Nova.Scene;

struct SceneStats {
	public int sphereCount;
	public uint64 sphereBytes;

	public int triangleCount;
	public uint64 triangleBytes;

	public int meshCount;
	public uint64 meshBytes;

	public int materialCount;
	public uint64 materialBytes;

	public int textureCount;
	public uint64 textureBytes;
}

interface ISceneBuilder {
	void SetCamera(Vec3f position, Vec3f lookAt, float fov);



	Result<uint32> CreateImage(int width, int height, uint8* pixels);

	uint32 CreateTexture(uint32 imageId, TextureFilter min, TextureFilter mag);

	uint32 CreateMaterial(Material material);

	IMeshBuilder CreateMesh(int triangleCount, out uint32 meshId);



	void AddSphere(Vec3f position, float radius, uint32 materialId);

	void AddMesh(uint32 meshId, MeshTransform transform);



	int TextureCount { get; }

	SceneStats Stats { get; }
}

interface IMeshBuilder : IDisposable {
	void AddTriangle(Vec3f[3] positions, Vec3f[3] normals, Vec2f[3] uvs, uint32 materialId);
}