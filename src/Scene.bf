using System;
using System.Collections;

using Nova.Gpu;

namespace Nova;

interface IByteSize {
	int Count { get; }
	uint64 Bytes { get; }
}

struct ByteSize : IByteSize {
	private int count;
	private uint64 bytes;

	public this(int count, uint64 bytes) {
		this.count = count;
		this.bytes = bytes;
	}

	public int Count => count;
	public uint64 Bytes => bytes;
}

struct ByteSize<T> : IByteSize {
	private int count;

	public this(int count) {
		this.count = count;
	}

	public int Count => count;
	public uint64 Bytes => (.) sizeof(T) * (.) count;

	public static implicit operator Self(int count) => .(count);
}

struct ByteSize<T1, T2> : IByteSize {
	private int count1;
	private int count2;

	public this(int count1, int count2) {
		this.count1 = count1;
		this.count2 = count2;
	}

	public int Count => count1;
	public uint64 Bytes => (.) sizeof(T1) * (.) count1 + (.) sizeof(T2) * (.) count2;
}

struct SceneStats {
	public ByteSize<Sphere, BVH.Node> spheres;
	public ByteSize<Triangle, BVH.Node> triangles;
	public ByteSize<MeshInstance, BVH.Node> meshes;

	public ByteSize<Material> materials;
	public ByteSize textures;
}

struct MeshTransform {
	public Vec3f position;
	public Quaternion rotation;
	public Vec3f scale;

	public Mat4 originMatrix;
	public Mat4 directionMatrix;

	public this(Vec3f position, Quaternion rotation, Vec3f scale, Mat4 originMatrix, Mat4 directionMatrix) {
		this.position = position;
		this.rotation = rotation;
		this.scale = scale;
		this.originMatrix = originMatrix;
		this.directionMatrix = directionMatrix;
	}

	public this(Vec3f position, Quaternion rotation, Vec3f scale) {
		this.position = position;
		this.rotation = rotation;
		this.scale = scale;

		this.originMatrix = (Mat4.Identity().Translate(position) * rotation.Matrix.Transpose()).Scale(scale);
		this.directionMatrix = (Mat4.Identity() * rotation.Matrix.Transpose()).Scale(scale);
	}
}

struct Texture : this(uint32 imageId, TextureFilter min, TextureFilter mag) {}

class Scene {
	public String folderPath ~ delete _;

	public Vec3f cameraPos;
	public Vec3f cameraLookAt;
	public float cameraFov;

	private append List<Sphere> spheres = .(32);

	private append List<BVH.Node> triangleBvh = .(1024 * 4);
	private append List<Triangle> triangles = .(1024 * 8);

	private append Dictionary<int, uint32> meshInstaceRootBvhIndices = .(32);
	private append List<MeshInstance> meshInstances = .();

	private append List<Material> materials = .(8);
	private append List<Image> images = .(8);
	private append List<Texture> textures = .(8);

	public this(StringView folderPath) {
		this.folderPath = new .(folderPath);
	}

	public ~this() {
		ClearAndDeleteItems!(images);
	}

	public SceneStats Stats { get {
		uint64 textureBytes = 0;

		for (Image image in images) {
			textureBytes += (.) (image.width * image.height * 4);
		}

		return .() {
			spheres = .(spheres.Count, 0),
			triangles = .(triangles.Count, triangleBvh.Count),
			meshes = .(meshInstances.Count, 0),

			materials = materials.Count,
			textures = .(images.Count, textureBytes)
		};
	} }

	public int TextureCount => textures.Count;

	public void Add(Sphere sphere) {
		spheres.Add(sphere);
	}

	public void Add(Triangle triangle) {
		triangles.Add(triangle);
	}

	private uint32 GetMaterialIndex(GLTF.Material* mat) {
		Material material = .();

		if (mat != null) {
			mixin GetTextureIndex(GLTF.TextureView view) {
				uint32 index = 0;

				if (view.texture != null) {
					for (uint32 i < (.) LuaBindings.DATA.texturesCount) {
						if (&LuaBindings.DATA.textures[i] == view.texture) {
							index = i + 1;
							break;
						}
					}
				}

				index
			}

			if (mat.hasPbrMetallicRoughness != 0) {
				GLTF.PbrMetallicRoughness v = mat.pbrMetallicRoughness;

				material.albedo = .(v.baseColorFactor);
				material.metallic = v.metallicFactor;
				material.roughness = v.roughnessFactor;

				material.albedoTexture = GetTextureIndex!(v.baseColorTexture);
				material.metallicRoughnessTexture = GetTextureIndex!(v.metallicRoughnessTexture);
			}

			if (mat.hasSpecular != 0) {
				material.specularTint = mat.specular.factor;
			}

			material.emission = Vec3f(mat.emissiveFactor);
			if (mat.hasEmissiveStrength != 0) {
				material.emission *= mat.emissiveStrength.strength;
			}

			material.emissionTexture = GetTextureIndex!(mat.emissiveTexture);

			if (mat.hasClearcoat != 0) {
				GLTF.Clearcoat v = mat.clearcoat;

				material.clearcoat = v.factor;
				material.clearcoatRoughness = v.roughnessFactor;
			}

			if (mat.hasIor != 0) {
				material.ior = mat.ior.ior;
			}

			material.normalTexture = GetTextureIndex!(mat.normalTexture);
		}
		else {
			material.albedo = .(0.8f, 0.8f, 0.8f, 0);
		}

		int index = materials.IndexOf(material);
		if (index != -1) return (.) index;

		materials.Add(material);
		return (.) materials.Count - 1;
	}

	public Result<void> Add(GLTF.Mesh* mesh, MeshTransform transform) {
		uint32 rootBvhIndex;

		float scale = 1;

		if (!meshInstaceRootBvhIndices.TryGetValue(GLTF.Mesh.GetHashCode(mesh), out rootBvhIndex)) {
			List<Triangle> meshTriangles = new .(1024);
			defer delete meshTriangles;

			// Loop primitives
			for (uint primitiveI < mesh.primitivesCount) {
				GLTF.Primitive* primitive = &mesh.primitives[primitiveI];
	
				if (primitive.type != .Triangles) {
					return .Err;
				}
	
				// Get attributes
				GLTF.Attribute* positionAttribute = null;
				GLTF.Attribute* normalAttribute = null;
				GLTF.Attribute* texcoordAttribute = null;
	
				for (uint attributeI < primitive.attributesCount) {
					GLTF.Attribute* attribute = &primitive.attributes[attributeI];
	
					if (String.Equals(attribute.name, "POSITION")) positionAttribute = attribute;
					else if (String.Equals(attribute.name, "NORMAL")) normalAttribute = attribute;
					else if (String.Equals(attribute.name, "TEXCOORD_0")) texcoordAttribute = attribute;
				}
	
				if (positionAttribute == null) {
					return .Err;
				}

				uint32 materialIndex = GetMaterialIndex(primitive.material);
	
				// Loop indices
				for (uint indexI = 0; indexI < primitive.indices.count; indexI += 3) {
					uint i0 = primitive.indices.bufferView.Get<uint16>(indexI + 0);
					uint i1 = primitive.indices.bufferView.Get<uint16>(indexI + 1);
					uint i2 = primitive.indices.bufferView.Get<uint16>(indexI + 2);
	
					Vec3f v0 = positionAttribute.data.bufferView.Get<Vec3f>(i0) * scale;
					Vec3f v1 = positionAttribute.data.bufferView.Get<Vec3f>(i1) * scale;
					Vec3f v2 = positionAttribute.data.bufferView.Get<Vec3f>(i2) * scale;

					Vec3f n0;
					Vec3f n1;
					Vec3f n2;

					if (normalAttribute != null) {
						n0 = normalAttribute.data.bufferView.Get<Vec3f>(i0);
						n1 = normalAttribute.data.bufferView.Get<Vec3f>(i1);
						n2 = normalAttribute.data.bufferView.Get<Vec3f>(i2);
					}
					else {
						n0 = n1 = n2 = (v1 - v0).Cross(v2 - v0).Normalized;
					}

					Vec2f t0 = .ZERO;
					Vec2f t1 = .ZERO;
					Vec2f t2 = .ZERO;

					if (texcoordAttribute != null) {
						t0 = texcoordAttribute.data.bufferView.Get<Vec2f>(i0);
						t1 = texcoordAttribute.data.bufferView.Get<Vec2f>(i1);
						t2 = texcoordAttribute.data.bufferView.Get<Vec2f>(i2);
					}
					
					meshTriangles.Add(.(
						v0,
						//v0 - v1,
						v1 - v0,
						v2 - v0,
						.(n0, n1, n2),
						.(t0, t1, t2),
						.(materialIndex,)
					));
				}
			}

			// Build BVH
			BVH.Result result = BVH.Build(.(), meshTriangles);

			// Copy mesh BVH and triangles to global lists
			rootBvhIndex = (.) triangleBvh.Count;
			uint32 rootTriangleIndex = (.) triangles.Count;

			for (int i < result.nodeCount) {
				BVH.Node node = result.nodes[i];

				if (node.count == 0) node.start += rootBvhIndex;
				else node.start += rootTriangleIndex;

				triangleBvh.Add(node);
			}

			triangles.AddRange(meshTriangles);

			// Free BVH
			BVH.Free(result);

			// Add index to dictionary
			meshInstaceRootBvhIndices[GLTF.Mesh.GetHashCode(mesh)] = rootBvhIndex;
		}

		// Add mesh instance
		Mat4 originMatrix = Mat4.Identity();
		Mat4 directionMatrix = Mat4.Identity();

		void Translate(Vec3f v) {
			originMatrix = originMatrix.Translate(v);
		}

		void Rotate(Quaternion quat) {
			Mat4 matrix = quat.Matrix.Transpose(); // both Transpose() and Inverse() seems to work here

			originMatrix *= matrix;
			directionMatrix *= matrix;
		}

		void Scale(Vec3f v) {
			originMatrix = originMatrix.Scale(v);
			directionMatrix = directionMatrix.Scale(v);
		}

		Translate(transform.position);
		Rotate(transform.rotation);
		Scale(transform.scale);

		originMatrix = transform.originMatrix;
		directionMatrix = transform.directionMatrix;

		AABB4f aabb = triangleBvh[rootBvhIndex].aabb;
		AABB4f aabbNew = .(.MAX, .MIN);

		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.min.x, aabb.min.y, aabb.min.z, 1)));
		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.min.x, aabb.min.y, aabb.max.z, 1)));
		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.max.x, aabb.min.y, aabb.max.z, 1)));
		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.max.x, aabb.min.y, aabb.min.z, 1)));

		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.min.x, aabb.max.y, aabb.min.z, 1)));
		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.min.x, aabb.max.y, aabb.max.z, 1)));
		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.max.x, aabb.max.y, aabb.max.z, 1)));
		aabbNew.Grow((.) (originMatrix * Vec4f(aabb.max.x, aabb.max.y, aabb.min.z, 1)));

		meshInstances.Add(.(
			originMatrix,
			directionMatrix,
			aabbNew,
			rootBvhIndex
		));

		return .Ok;
	}

	public void AddImage(Image image) {
		images.Add(image);
	}

	public void AddTexture(Texture texture) {
		textures.Add(texture);
	}

	// Buffers

	public Result<GpuBuffer> CreateGlobalDataBuffer(Gpu gpu, int width, int height) {
		GpuBuffer buffer = gpu.CreateBuffer(.Uniform, sizeof(GlobalData));

		GlobalData data = .();

		data.widthF = width;
		data.heightF = height;
		data.widthI = (.) width;
		data.heightI = (.) height;
		data.camera = .(cameraPos, cameraLookAt, cameraFov, (float) width / height);

		gpu.Upload(buffer, &data).GetOrPropagate!();
		return buffer;
	}

	public Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateSphereBuffers(Gpu gpu) => CreateBvhBuffers(gpu, spheres);

	public Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateTriangleBuffers(Gpu gpu) {
		GpuBuffer bvhBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(BVH.Node) * triangleBvh.Count));
		GpuBuffer primitivesBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(Triangle) * triangles.Count));

		gpu.Upload(bvhBuffer, triangleBvh.Ptr).GetOrPropagate!();
		if (triangles.Count > 0) gpu.Upload(primitivesBuffer, triangles.Ptr).GetOrPropagate!();

		return (bvhBuffer, primitivesBuffer);
	}

	public Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateMeshInstanceBuffers(Gpu gpu) => CreateBvhBuffers(gpu, meshInstances);

	private Result<(GpuBuffer bvhBuffer, GpuBuffer primitivesBuffer)> CreateBvhBuffers<T>(Gpu gpu, List<T> primitives) where T : IPrimitive {
		BVH.Result bvh = BVH.Build(.(), primitives);
		defer BVH.Free(bvh);

		GpuBuffer bvhBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(BVH.Node) * bvh.nodeCount)).GetOrPropagate!();
		GpuBuffer primitivesBuffer = gpu.CreateBuffer(.Storage, (.) (sizeof(T) * primitives.Count)).GetOrPropagate!();

		gpu.Upload(bvhBuffer, bvh.nodes).GetOrPropagate!();
		if (primitives.Count > 0) gpu.Upload(primitivesBuffer, primitives.Ptr).GetOrPropagate!();

		return (bvhBuffer, primitivesBuffer);
	}

	public Result<GpuBuffer> CreateMaterialsBuffer(Gpu gpu) {
		GpuBuffer buffer = gpu.CreateBuffer(.Storage, (.) (sizeof(Material) * materials.Count)).GetOrPropagate!();

		gpu.Upload(buffer, materials.Ptr).GetOrPropagate!();

		return buffer;
	}

	public mixin GetSampledImageArray(Gpu gpu) {
		GpuSampledImage[] images = scope:mixin .[textures.Count];

		for (int i < textures.Count) {
			Texture texture = textures[i];
			Image image = this.images[texture.imageId];

			GpuImage img = gpu.CreateImage(.RGBA8u, image.width, image.height, true);
			gpu.Upload(img, image);

			images[i] = .(img, gpu.GetSampler(texture.min, texture.mag));
		}

		scope:mixin GpuSampledImageArray(gpu, images)
	}
}