using System;
using System.Collections;

using Nova.Gpu;
using Nova.BVH;
using Nova.Math;
using Nova.Profiler;

namespace Nova.Scene;

class GpuSceneBuilder : ISceneBuilder {
	private Gpu gpu;

	private Vec3f cameraPos;
	private Vec3f cameraLookAt;
	private float cameraFov;

	private append List<GpuImage> images = .(32);
	private append List<GpuSampledImage> textures = .(32);
	private append List<Material> materials = .(64);

	private append List<GpuMeshBuilder> meshes = .(64);

	private append List<Sphere> spheres = .(64);
	private append List<MeshInstance> meshInstances = .(64);

	public this(Gpu gpu) {
		this.gpu = gpu;
	}

	public ~this() {
		meshes.ClearAndDeleteItems();
	}

	public void SetCamera(Vec3f position, Vec3f lookAt, float fov) {
		cameraPos = position;
		cameraLookAt = lookAt;
		cameraFov = fov;
	}


	
	[Profile]
	public Result<uint32> CreateImage(int width, int height, uint8* pixels) {
		GpuImage image = gpu.CreateImage(.RGBA8u, width, height, true).GetOrPropagate!();
		gpu.Upload(image, pixels).GetOrPropagate!();

		images.Add(image);
		return (.) images.Count - 1;
	}
	
	[Profile]
	public uint32 CreateTexture(uint32 imageId, TextureFilter min, TextureFilter mag) {
		textures.Add(.(images[imageId], gpu.GetSampler(min, mag)));
		return (.) textures.Count - 1;
	}
	
	[Profile]
	public uint32 CreateMaterial(Material material) {
		materials.Add(material);
		return (.) materials.Count - 1;
	}
	
	[Profile]
	public IMeshBuilder CreateMesh(int triangleCount, out uint32 meshId) {
		GpuMeshBuilder mesh = new GpuMeshBuilder(this, triangleCount);

		meshes.Add(mesh);
		meshId = (.) meshes.Count - 1;

		return mesh;
	}



	public void AddSphere(Vec3f position, float radius, uint32 materialId) {
		spheres.Add(.(position, radius, .(materialId,)));
	}

	public void AddMesh(uint32 meshId, MeshTransform transform) {
		GpuMeshBuilder mesh = meshes[meshId];

		meshInstances.Add(.(transform.originMatrix, transform.directionMatrix, mesh.aabb, 0));
		mesh.instanceIds.Add((.) meshInstances.Count - 1);
	}



	public int TextureCount => textures.Count;

	public SceneStats Stats { get {
		// Triangle stats
		int triangleCount = 0;
		int triangleNodeCount = 0;

		for (let mesh in meshes) {
			triangleCount += mesh.triangles.Count;
			triangleNodeCount += mesh?.bvh.nodes.Count ?? 0;
		}

		// Texture stats
		uint64 textureBytes = 0;

		for (let image in images) {
			textureBytes += (.) (image.width * image.height * image.format.Size);
		}

		// Return
		return .() {
			sphereCount = spheres.Count,
			sphereBytes = (.) (sizeof(Sphere) * spheres.Count),

			triangleCount = triangleCount,
			triangleBytes = (.) (sizeof(Triangle) * triangleCount + sizeof(BVH.Node) * triangleNodeCount),

			meshCount = meshes.Count,
			meshBytes = (.) (sizeof(MeshInstance) * meshes.Count),

			materialCount = materials.Count,
			materialBytes = (.) (sizeof(Material) * materials.Count),

			textureCount = images.Count,
			textureBytes = textureBytes
		};
	} }


	
	[Profile]
	public Result<GpuBuffer> CreateSceneDataBuffer(Gpu gpu, int width, int height) {
		GpuBuffer buffer = gpu.CreateBuffer(.Uniform, sizeof(GlobalData)).GetOrPropagate!();

		GlobalData data = .();

		data.widthF = width;
		data.heightF = height;
		data.widthI = (.) width;
		data.heightI = (.) height;
		data.camera = .(cameraPos, cameraLookAt, cameraFov, (float) width / height);

		gpu.Upload(buffer, &data).GetOrPropagate!();
		return buffer;
	}
	
	[Profile]
	public Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateSphereBuffers(Gpu gpu) => CreateBvhBuffers(gpu, spheres);
	
	[Profile]
	public Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateTriangleBuffers(Gpu gpu) {
		int triangleCount = 0;
		int nodeCount = 0;

		for (let mesh in meshes) {
			triangleCount += mesh.triangles.Count;
			nodeCount += mesh.bvh.nodes.Count;
		}

		Triangle[] triangles = new .[triangleCount];
		defer delete triangles;

		BVH.Node[] nodes = new .[nodeCount];
		defer delete nodes;

		int triangleOffset = 0;
		int nodeOffset = 0;

		for (let mesh in meshes) {
			Internal.MemCpy(&triangles[triangleOffset], mesh.triangles.Ptr, sizeof(Triangle) * mesh.triangles.Count);
			Internal.MemCpy(&nodes[nodeOffset], mesh.bvh.nodes.Ptr, sizeof(BVH.Node) * mesh.bvh.nodes.Count);

			for (int i = nodeOffset; i < nodeOffset + mesh.bvh.nodes.Count; i++) {
				BVH.Node* node = &nodes[i];

				if (node.count == 0) node.start += (.) nodeOffset;
				else node.start += (.) triangleOffset;
			}

			for (let instanceId in mesh.instanceIds) {
				meshInstances[instanceId].rootBvhIndex = (.) nodeOffset;
			}
			
			triangleOffset += mesh.triangles.Count;
			nodeOffset += mesh.bvh.nodes.Count;
		}

		GpuBuffer bvhBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(BVH.Node) * nodeCount)).GetOrPropagate!();
		GpuBuffer primitivesBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(Triangle) * triangleCount)).GetOrPropagate!();

		gpu.Upload(bvhBuffer, nodes.Ptr).GetOrPropagate!();
		if (triangleCount > 0) gpu.Upload(primitivesBuffer, triangles.Ptr).GetOrPropagate!();

		return (bvhBuffer, primitivesBuffer);
	}
	
	[Profile]
	public Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateMeshInstanceBuffers(Gpu gpu) => CreateBvhBuffers(gpu, meshInstances);

	private Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateBvhBuffers<T>(Gpu gpu, List<T> primitives) where T : IPrimitive {
		// Theoretically the simple brute-force approach should produce slightly better trees at the cost of build time
		// That doesn't matter here because there is only ever going to be a few mesh instances compared to triangles
		BVH bvh = scope SimpleSahBvhBuilder<T>(primitives).Build();
		bvh.ReorderPrimitives(primitives);
		defer delete bvh;

		if (primitives.IsEmpty) {
			bvh.nodes[0].aabb = .(.ZERO, .ZERO);
		}

		GpuBuffer bvhBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(BVH.Node) * bvh.nodes.Count)).GetOrPropagate!();
		GpuBuffer primitivesBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(T) * primitives.Count)).GetOrPropagate!();

		gpu.Upload(bvhBuffer, bvh.nodes.Ptr).GetOrPropagate!();
		if (primitives.Count > 0) gpu.Upload(primitivesBuffer, primitives.Ptr).GetOrPropagate!();

		return (bvhBuffer, primitivesBuffer);
	}
	
	[Profile]
	public Result<GpuBuffer> CreateMaterialsBuffer(Gpu gpu) {
		GpuBuffer buffer = gpu.CreateBuffer(.Storage, (.) (sizeof(Material) * materials.Count)).GetOrPropagate!();

		gpu.Upload(buffer, materials.Ptr).GetOrPropagate!();

		return buffer;
	}

	public mixin GetSampledImageArray(Gpu gpu) {
		GpuSampledImage[] textures = scope:mixin .[textures.Count];

		for (int i < textures.Count) {
			textures[i] = this.textures[i];
		}

		scope:mixin GpuSampledImageArray(gpu, textures)
	}

	

	private class GpuMeshBuilder : IMeshBuilder {
		private GpuSceneBuilder scene;

		public Triangle[] triangles;
		private int triangleI;

		public AABB3f aabb;
		public BVH bvh ~ delete _;

		public append List<uint32> instanceIds = .(16);

		[AllowAppend]
		public this(GpuSceneBuilder scene, int triangleCount) {
			Triangle[] triangles = append .[triangleCount];

			this.scene = scene;
			this.triangles = triangles;
			this.aabb = .(.MAX, .MIN);
		}

		public void AddTriangle(Vec3f[3] positions, Vec3f[3] normals, Vec2f[3] uvs, uint32 materialId) {
			triangles[triangleI++] = .(
				positions[0],
				positions[1] - positions[0],
				positions[2] - positions[0],
				.(normals[0], normals[1], normals[2]),
				.(uvs[0], uvs[1], uvs[2]),
				.(materialId,)
			);

			for (let position in positions) {
				aabb.Grow(position);
			}
		}

		public void Dispose() {
			bvh = scope BinnedSahBvhBuilder<Triangle>(triangles).Build();
		}
	}
}