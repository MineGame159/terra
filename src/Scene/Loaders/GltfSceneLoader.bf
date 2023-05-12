using System;
using System.Collections;

using Terra.Gpu;
using Terra.Math;
using Terra.Profiler;

namespace Terra.Scene.Loaders;

class GltfSceneLoader : ISceneLoader {
	private append String path = .();

	private append Dictionary<Gltf.Image, uint32> imageIds = .();
	private append Dictionary<Gltf.Texture, uint32> textureIds = .();
	private append Dictionary<Gltf.Mesh, uint32> meshIds = .();
	
	public this(StringView path) {
		this.path.Set(path);
	}

	[Profile]
	public Result<void> Load(ISceneBuilder scene) {
		Gltf gltf = Gltf.Parse(path).GetOrPropagate!();
		defer delete gltf;

		SetCamera(scene, gltf).GetOrPropagate!();
		CreateTextures(scene, gltf).GetOrPropagate!();
		CreateMeshes(scene, gltf).GetOrPropagate!();
		AddMeshes(scene, gltf).GetOrPropagate!();

		return .Ok;
	}

	[Profile]
	private Result<void> SetCamera(ISceneBuilder scene, Gltf gltf) {
		for (let (node, transform) in scope Gltf.NodeEnumerator(gltf.scene, false)) {
			if (node.camera != null) {
				Quaternion rotation = node.rotation;
				Vec3f position = .((.) node.translation.x, (.) node.translation.y, (.) node.translation.z);

				Mat4 mat = rotation.Matrix.Transpose();
				Vec3f dir = (.) (mat * Vec4f(0, 0, -1, 0));

				float fov = (.) Math.RadiansToDegrees(node.camera.yFov);

				scene.SetCamera(position, position + dir, fov);
				break;
			}
		}

		return .Ok;
	}

	[Profile]
	private Result<void> CreateTextures(ISceneBuilder scene, Gltf gltf) {
		// Images
		for (let image in gltf.images) {
			uint32 id = scene.CreateImage(image.width, image.height, image.data).GetOrPropagate!();
			imageIds[image] = id;
		}

		// Textures
		for (let texture in gltf.textures) {
			uint32 imageId = imageIds.GetValue(texture.image).GetOrPropagate!();
			
			TextureFilter min;

			switch (texture.sampler.min) {
			case .Nearest, .NearestMipmapNearest, .NearestMipmapLinear:	min = .Nearest;
			case .Linear, .LinearMipmapNearest, .LinearMipmapLinear:	min = .Linear;
			default:													Runtime.NotImplemented();
			}

			TextureFilter mag;

			switch (texture.sampler.mag) {
			case .Nearest:	mag = .Nearest;
			case .Linear:	mag = .Linear;
			default:		Runtime.NotImplemented();
			}

			uint32 id = scene.CreateTexture(imageId, min, mag);
			textureIds[texture] = id;
		}

		return .Ok;
	}

	[Profile]
	private Result<void> CreateMeshes(ISceneBuilder scene, Gltf gltf) {
		for (let mesh in gltf.meshes) {
			// Get number of triangles
			int triangleCount = 0;

			for (let primitive in mesh.primitives) {
				if (primitive.mode != .Triangles) return .Err;

				triangleCount += (.) primitive.indices.count / 3;
			}

			// Create mesh
			uint32 id;

			using (let builder = scene.CreateMesh(triangleCount, out id)) {
				// Loop primitives
				for (let primitive in mesh.primitives) {
					// Create material
					uint32 materialId = CreateMaterial(scene, primitive.material).GetOrPropagate!();

					// Get attributes
					Gltf.Accessor positionAttribute = null;
					Gltf.Accessor normalAttribute = null;
					Gltf.Accessor texcoordAttribute = null;

					for (let (name, accessor) in primitive.attributes) {
						if (name == "POSITION") positionAttribute = accessor;
						else if (name == "NORMAL") normalAttribute = accessor;
						else if (name == "TEXCOORD_0") texcoordAttribute = accessor;
					}

					if (positionAttribute == null) return .Err;

					// Loop indices
					for (uint indexI = 0; indexI < (.) primitive.indices.count; indexI += 3) {
						// Inidices
						uint i0 = primitive.indices.view.Get<uint16>(indexI + 0);
						uint i1 = primitive.indices.view.Get<uint16>(indexI + 1);
						uint i2 = primitive.indices.view.Get<uint16>(indexI + 2);

						// Positions
						Vec3f[3] positions = .(
							positionAttribute.view.Get<Vec3f>(i0),
							positionAttribute.view.Get<Vec3f>(i1),
							positionAttribute.view.Get<Vec3f>(i2)
						);

						// Normals
						Vec3f[3] normals;

						if (normalAttribute != null) {
							normals = .(
								normalAttribute.view.Get<Vec3f>(i0),
								normalAttribute.view.Get<Vec3f>(i1),
								normalAttribute.view.Get<Vec3f>(i2)
							);
						}
						else {
							Vec3f normal = (positions[1] - positions[0]).Cross(positions[2] - positions[0]).Normalized;
							normals = .(normal, normal, normal);
						}

						// UVs
						Vec2f[3] uvs = .();

						if (texcoordAttribute != null) {
							uvs = .(
								texcoordAttribute.view.Get<Vec2f>(i0),
								texcoordAttribute.view.Get<Vec2f>(i1),
								texcoordAttribute.view.Get<Vec2f>(i2)
							);
						}

						// Add triangle
						builder.AddTriangle(positions, normals, uvs, materialId);
					}
				}
			}

			meshIds[mesh] = id;
		}

		return .Ok;
	}

	[Profile]
	private Result<uint32> CreateMaterial(ISceneBuilder scene, Gltf.Material material) {
		Material mat = .();

		if (material != null) {
			mixin GetTextureIndex(Gltf.Texture texture) {
				uint32 id = 0;

				if (texture != null) {
					id = textureIds.GetValue(texture).GetOrPropagate!() + 1;
				}

				id
			}

			// Metallic / roughness
			if (material.pbrMetallicRoughness.HasValue) {
				Gltf.PbrMetallicRoughness v = material.pbrMetallicRoughness.Value;

				mat.albedo = v.baseColorFactor;
				mat.metallic = v.metallicFactor;
				mat.roughness = v.roughnessFactor;

				mat.albedoTexture = GetTextureIndex!(v.baseColorTexture);
				mat.metallicRoughnessTexture = GetTextureIndex!(v.metallicRoughnessTexture);
			}

			// Specular
			if (material.specular.HasValue) {
				mat.specularTint = material.specular.Value.factor;
			}

			// Emission
			if (material.emission.HasValue) {
				Gltf.Emission v = material.emission.Value;

				mat.emission = v.factor * v.strength;
				mat.emissionTexture = GetTextureIndex!(v.texture);
			}

			// Clearcoat
			if (material.clearcoat.HasValue) {
				Gltf.Clearcoat v = material.clearcoat.Value;

				mat.clearcoat = v.factor;
				mat.clearcoatRoughness = v.roughnessFactor;
			}

			// IOR
			if (material.ior.HasValue) {
				mat.ior = material.ior.Value.ior;
			}

			// Normal texture
			mat.normalTexture = GetTextureIndex!(material.normalTexture);
		}
		else {
			mat.albedo = .(0.8f, 0.8f, 0.8f, 0);
		}

		return scene.CreateMaterial(mat);
	}

	[Profile]
	private Result<void> AddMeshes(ISceneBuilder scene, Gltf gltf) {
		for (let (node, transform) in scope Gltf.NodeEnumerator(gltf.scene, true)) {
			uint32 meshId = meshIds.GetValue(node.mesh).GetOrPropagate!();
			scene.AddMesh(meshId, transform);
		}

		return .Ok;
	}
}