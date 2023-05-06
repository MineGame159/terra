using System;
using System.Collections;

using Nova.Gpu;
using Nova.Math;

namespace Nova.Scene;

class GltfSceneLoader : ISceneLoader {
	private append String path = .();

	private append Dictionary<GLTF.Image*, uint32> imageIds = .();
	private append Dictionary<GLTF.Texture*, uint32> textureIds = .();
	private append Dictionary<GLTF.Mesh*, uint32> meshIds = .();

	public this(StringView path) {
		this.path.Set(path);
	}

	public Result<void> Load(ISceneBuilder scene) {
		GLTF.Data* data = Parse().GetOrPropagate!();
		defer GLTF.Free(data);

		SetCamera(scene, data).GetOrPropagate!();
		CreateTextures(scene, data).GetOrPropagate!();
		CreateMeshes(scene, data).GetOrPropagate!();
		AddMeshes(scene, data).GetOrPropagate!();

		return .Ok;
	}

	private Result<void> AddMeshes(ISceneBuilder scene, GLTF.Data* data) {
		for (let (node, transform) in scope GLTF.NodeEnumerator(data, true)) {
			uint32 meshId = meshIds.GetValue(node.mesh).GetOrPropagate!();
			scene.AddMesh(meshId, transform);
		}

		return .Ok;
	}

	private Result<void> CreateMeshes(ISceneBuilder scene, GLTF.Data* data) {
		for (var mesh in ref data.Meshes) {
			// Get number of triangles
			int triangleCount = 0;

			for (let primitive in mesh.Primitives) {
				if (primitive.type != .Triangles) return .Err;

				triangleCount += (.) primitive.indices.count / 3;
			}

			// Create mesh
			uint32 id;

			using (let builder = scene.CreateMesh(triangleCount, out id)) {
				// Loop primitives
				for (let primitive in mesh.Primitives) {
					// Create material
					uint32 materialId = CreateMaterial(scene, primitive.material).GetOrPropagate!();

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
	
					if (positionAttribute == null) return .Err;

					// Loop indices
					for (uint indexI = 0; indexI < primitive.indices.count; indexI += 3) {
						// Inidices
						uint i0 = primitive.indices.bufferView.Get<uint16>(indexI + 0);
						uint i1 = primitive.indices.bufferView.Get<uint16>(indexI + 1);
						uint i2 = primitive.indices.bufferView.Get<uint16>(indexI + 2);

						// Positions
						Vec3f[3] positions = .(
							positionAttribute.data.bufferView.Get<Vec3f>(i0),
							positionAttribute.data.bufferView.Get<Vec3f>(i1),
							positionAttribute.data.bufferView.Get<Vec3f>(i2)
						);

						// Normals
						Vec3f[3] normals;

						if (normalAttribute != null) {
							normals = .(
								normalAttribute.data.bufferView.Get<Vec3f>(i0),
								normalAttribute.data.bufferView.Get<Vec3f>(i1),
								normalAttribute.data.bufferView.Get<Vec3f>(i2)
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
								texcoordAttribute.data.bufferView.Get<Vec2f>(i0),
								texcoordAttribute.data.bufferView.Get<Vec2f>(i1),
								texcoordAttribute.data.bufferView.Get<Vec2f>(i2)
							);
						}

						// Add triangle
						builder.AddTriangle(positions, normals, uvs, materialId);
					}
				}
			}

			meshIds[&mesh] = id;
		}

		return .Ok;
	}

	private Result<uint32> CreateMaterial(ISceneBuilder scene, GLTF.Material* material) {
		Material mat = .();

		if (material != null) {
			mixin GetTextureIndex(GLTF.TextureView view) {
				uint32 id = 0;

				if (view.texture != null) {
					id = textureIds.GetValue(view.texture).GetOrPropagate!() + 1;
				}

				id
			}

			// Metallic / roughness
			if (material.hasPbrMetallicRoughness != 0) {
				GLTF.PbrMetallicRoughness v = material.pbrMetallicRoughness;

				mat.albedo = .(v.baseColorFactor);
				mat.metallic = v.metallicFactor;
				mat.roughness = v.roughnessFactor;

				mat.albedoTexture = GetTextureIndex!(v.baseColorTexture);
				mat.metallicRoughnessTexture = GetTextureIndex!(v.metallicRoughnessTexture);
			}

			// Specular
			if (material.hasSpecular != 0) {
				mat.specularTint = material.specular.factor;
			}

			// Emission
			mat.emission = Vec3f(material.emissiveFactor);

			if (material.hasEmissiveStrength != 0) {
				mat.emission *= material.emissiveStrength.strength;
			}

			mat.emissionTexture = GetTextureIndex!(material.emissiveTexture);

			// Clearcoat
			if (material.hasClearcoat != 0) {
				GLTF.Clearcoat v = material.clearcoat;

				mat.clearcoat = v.factor;
				mat.clearcoatRoughness = v.roughnessFactor;
			}

			// IOR
			if (material.hasIor != 0) {
				mat.ior = material.ior.ior;
			}

			// Normal texture
			mat.normalTexture = GetTextureIndex!(material.normalTexture);
		}
		else {
			mat.albedo = .(0.8f, 0.8f, 0.8f, 0);
		}

		return scene.CreateMaterial(mat);
	}

	private Result<void> CreateTextures(ISceneBuilder scene, GLTF.Data* data) {
		// Images
		for (var image in ref data.Images) {
			Image img = Image.Load(.(image.bufferView.Address, (.) image.bufferView.size)).GetOrPropagate!();

			uint32 id = scene.CreateImage(img.width, img.height, img.pixels).GetOrPropagate!();
			imageIds[&image] = id;

			delete img;
		}

		// Textures
		for (var texture in ref data.Textures) {
			uint32 imageId = imageIds.GetValue(texture.image).GetOrPropagate!();
			
			TextureFilter min;

			switch (texture.sampler.minFilter) {
			case 9728, 9984, 9986:	min = .Nearest;
			case 9729, 9985, 9987:	min = .Linear;
			default:	Runtime.NotImplemented();
			}

			TextureFilter mag;

			switch (texture.sampler.magFilter) {
			case 9728:	mag = .Nearest;
			case 9729:	mag = .Linear;
			default:	Runtime.NotImplemented();
			}

			uint32 id = scene.CreateTexture(imageId, min, mag);
			textureIds[&texture] = id;
		}

		return .Ok;
	}

	private Result<void> SetCamera(ISceneBuilder scene, GLTF.Data* data) {
		for (let (node, transform) in scope GLTF.NodeEnumerator(data, false)) {
			if (node.camera != null && node.camera.type == .Perspective) {
				Quaternion rotation = .(node.rotation);
				Vec3f position = .(node.translation[0], node.translation[1], node.translation[2]);

				Mat4 mat = rotation.Matrix.Transpose();
				Vec3f dir = (.) (mat * Vec4f(0, 0, -1, 0));

				float fov = Math.RadiansToDegrees(node.camera.data.perspective.yfov);

				scene.SetCamera(position, position + dir, fov);
				break;
			}
		}

		return .Ok;
	}

	private Result<GLTF.Data*> Parse() {
		GLTF.Options options = GLTF.GetDefaultOptions();
		GLTF.Data* data = null;

		GLTF.Result result = GLTF.ParseFile(&options, path, &data);
		if (result != .Success) return .Err;

		result = GLTF.LoadBuffers(&options, data, path);
		if (result != .Success) return .Err;

		return data;
	}
}