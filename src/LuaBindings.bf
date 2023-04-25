using System;

using Nova.Gpu;

namespace Nova;

static class LuaBindings {
	private static Scene SCENE;
	public static GLTF.Data* DATA;

	public static void Init(Lua.State state, Scene scene) {
		Lua.SetFunction(state, "set_camera", => SetCamera);
		Lua.SetFunction(state, "add_sphere", => AddSphere);
		Lua.SetFunction(state, "add_mesh", => AddMesh);

		Lua.SetFunction(state, "load_gltf", => LoadGltf);

		Lua.SetFunction(state, "random", => Random);

		SCENE = scene;
	}

	// Scene

	private static int32 SetCamera(Lua.State state) {
		Vec3f position = .ZERO;
		Vec3f lookAt = .(float.MaxValue, float.MaxValue, float.MaxValue);
		float yaw = 0;
		float pitch = 0;
		float fov = 0;

		GetVec3Field(state, -1, "position", ref position);
		GetVec3Field(state, -1, "look_at", ref lookAt);
		GetFloatField(state, -1, "yaw", ref yaw);
		GetFloatField(state, -1, "pitch", ref pitch);
		GetFloatField(state, -1, "fov", ref fov);

		if (lookAt.x == float.MaxValue) {
			lookAt = position + Utils.GetDirection(yaw, pitch);
			Internal.FatalError("");
		}

		SCENE.cameraPos = position;
		SCENE.cameraLookAt = lookAt;
		SCENE.cameraFov = fov;

		return 0;
	}

	private static int32 AddSphere(Lua.State state) {
		Vec3f center = GetVec3(state, -3);
		float radius = GetFloat(state, -2);
		Material material = GetMaterial(state, -1);

		SCENE.Add(Sphere(center, radius, material));
		return 0;
	}

	private static int32 AddMesh(Lua.State state) {
		GLTF.Mesh* mesh = *Lua.ToUserData<GLTF.Mesh*>(state, -2);
		MeshTransform transform = GetMeshTransform(state, -1);

		if (SCENE.Add(mesh, transform) == .Err) {
			return Lua.Error(state, "Failed to add mesh");
		}

		return 0;
	}

	// GLTF

	private static int32 LoadGltf(Lua.State state) {
		GLTF.Options options = GLTF.GetDefaultOptions();
		char8* path = scope $"{SCENE.folderPath}/{Lua.ToString(state, -1)}".CStr();
		GLTF.Data* data = null;

		GLTF.Result result = GLTF.ParseFile(&options, path, &data);
		if (result != .Success) {
			return Lua.Error(state, scope $"Failed to parse GLTF file: {result}");
		}

		result = GLTF.LoadBuffers(&options, data, path);
		if (result != .Success) {
			return Lua.Error(state, scope $"Failed to load GLTF buffers: {result}");
		}

		DATA = data;

		for (uint i < data.imagesCount) {
			GLTF.Image* image = &data.images[i];

			Image img;

			switch (Image.Load(.(image.bufferView.Address, (.)image.bufferView.size))) {
			case .Ok(let val):	img = val;
			case .Err:			Internal.FatalError("");
			}

			SCENE.AddImage(img);
		}

		for (uint i < data.texturesCount) {
			GLTF.Texture* texture = &data.textures[i];

			TextureFilter mag;

			switch (texture.sampler.magFilter) {
			case 9728:	mag = .Nearest;
			case 9729:	mag = .Linear;
			default:	Runtime.NotImplemented();
			}

			TextureFilter min;

			switch (texture.sampler.minFilter) {
			case 9728, 9984, 9986:	min = .Nearest;
			case 9729, 9985, 9987:	min = .Linear;
			default:	Runtime.NotImplemented();
			}

			SCENE.AddTexture(.((.) Span<GLTF.Image>(data.images, (.) data.imagesCount).IndexOf(*texture.image), min, mag));
		}

		Lua.NewUserData(state, data);

		Lua.CreateTable(state, 0, 2);

		Lua.PushClosure(state, => GltfIndex);
		Lua.SetField(state, -2, "__index");

		Lua.PushClosure(state, => FreeGltf);
		Lua.SetField(state, -2, "__gc");

		Lua.SetMetatable(state, -2);

		return 1;
	}

	private static int32 GltfIndex(Lua.State state) {
		StringView name = Lua.ToString(state, -1);

		int32 Push(Lua.Func func) {
			Lua.PushClosure(state, func);
			return 1;
		}

		switch (name) {
		case "get_camera":		return Push(=> GltfGetCamera);
		case "get_mesh":		return Push(=> GltfGetMesh);
		case "meshes":			return Push(=> GltfMeshes);
		default:				return Lua.Error(state, scope $"Invalid GLTF index: {name}");
		}
	}

	private static int32 GltfGetCamera(Lua.State state) {
		GLTF.Data* gltf = *Lua.ToUserData<GLTF.Data*>(state, -1);
		GLTF.Node* node = GLTF.GetPerspectiveCameraNode(gltf);

		if (node == null) {
			Lua.PushNil(state);
			return 1;
		}

		Quaternion rotation = .(node.rotation);
		Vec3f position = .(node.translation[0], node.translation[1], node.translation[2]);

		Lua.CreateTable(state, 0, 5);

		PushVec3(state, position);
		Lua.SetField(state, -2, "position");

		//Vec3 dir = Utils.GetDirection(rotation.Yaw + 180, rotation.Pitch);

		Mat4 mat = rotation.Matrix.Transpose();
		Vec3f dir = (.) (mat * Vec4f(0, 0, -1, 0));

		PushVec3(state, position + dir);
		Lua.SetField(state, -2, "look_at");

		Lua.PushNumber(state, rotation.Yaw);
		Lua.SetField(state, -2, "yaw");

		Lua.PushNumber(state, rotation.Pitch);
		Lua.SetField(state, -2, "pitch");

		Lua.PushNumber(state, Math.RadiansToDegrees(node.camera.data.perspective.yfov));
		Lua.SetField(state, -2, "fov");

		return 1;
	}

	private static int32 GltfGetMesh(Lua.State state) {
		GLTF.Data* gltf = *Lua.ToUserData<GLTF.Data*>(state, -2);
		Lua.Type type = Lua.GetType(state, -1);

		mixin Return(GLTF.Mesh* mesh) {
			if (mesh == null) {
				Lua.PushNil(state);
				return 1;
			}

			Lua.NewUserData(state, mesh);
			return 1;
		}

		if (type == .Number) {
			uint index = (.) Lua.ToNumber(state, -1);
			Return!((index >= 0 && index < gltf.meshesCount) ? &gltf.meshes[index] : null);
		}
		else if (type == .String) {
			StringView name = Lua.ToString(state, -1);
			GLTF.Mesh* mesh = null;

			for (uint i < gltf.meshesCount) {
				if (name == .(gltf.meshes[i].name)) {
					mesh = &gltf.meshes[i];
					break;
				}
			}

			Return!(mesh);
		}
		else {
			return Lua.Error(state, "Wrong argument");
		}
	}

	private static GLTF.NodeEnumerator enumerator;

	private static int32 GltfMeshes(Lua.State state) {
		GLTF.Data* gltf = *Lua.ToUserData<GLTF.Data*>(state, -1);
		enumerator = new .(gltf, true);
		
		Lua.NewUserData(state, Internal.UnsafeCastToPtr(enumerator));

		Lua.CreateTable(state, 0, 1);
		Lua.PushClosure(state, => GltfMeshesIterFree);
		Lua.SetField(state, -2, "__gc");
		Lua.SetMetatable(state, -2);

		Lua.PushClosure(state, => GltfMeshesIterNext, 1);

		return 1;
	}

	private static int32 GltfMeshesIterNext(Lua.State state) {
		GLTF.NodeEnumerator enumerator = (.) Internal.UnsafeCastToObject(*Lua.ToUserData<void*>(state, Lua.GetUpValueIndex(1)));

		if (enumerator.GetNext() case .Ok(let val)) {
			Lua.NewUserData(state, val.0.mesh);
			PushMeshTransform(state, val.1);

			return 2;
		}

		return 0;
	}

	private static int32 GltfMeshesIterFree(Lua.State state) {
		GLTF.NodeEnumerator enumerator = (.) Internal.UnsafeCastToObject(*Lua.ToUserData<void*>(state, -1));
		delete enumerator;

		return 0;
	}

	private static int32 FreeGltf(Lua.State state) {
		GLTF.Data* gltf = *Lua.ToUserData<GLTF.Data*>(state, -1);
		GLTF.Free(gltf);

		return 0;
	}

	// Utils

	private static int32 Random(Lua.State state) {
		int args = Lua.GetArgCount(state);

		if (args == 0) {
			Lua.PushNumber(state, Utils.Random());
		}
		else {
			float min = GetFloat(state, -2);
			float max = GetFloat(state, -1);

			Lua.PushNumber(state, Utils.Random(min, max));
		}

		return 1;
	}

	// Helpers

	private static float GetFloat(Lua.State state, int32 index) {
		return (.) Lua.ToNumber(state, index);
	}

	private static uint32 GetUint32(Lua.State state, int32 index) {
		return (.) Lua.ToNumber(state, index);
	}

	private static void GetFloatField(Lua.State state, int32 index, char8* name, ref float v) {
		if (Lua.GetField(state, index, name) == .Number) v = GetFloat(state, -1);
		Lua.Pop(state);
	}

	private static void GetUint32Field(Lua.State state, int32 index, char8* name, ref uint32 v) {
		if (Lua.GetField(state, index, name) == .Number) v = GetUint32(state, -1);
		Lua.Pop(state);
	}

	private static Vec3f GetVec3(Lua.State state, int32 index) {
		Lua.GetRawI(state, index, 1);
		float x = (.) Lua.ToNumber(state, -1);

		Lua.GetRawI(state, index - 1, 2);
		float y = (.) Lua.ToNumber(state, -1);

		Lua.GetRawI(state, index - 2, 3);
		float z = (.) Lua.ToNumber(state, -1);

		Lua.Pop(state, 3);
		return .(x, y, z);
	}

	private static Quaternion GetQuaternion(Lua.State state, int32 index) {
		Lua.GetRawI(state, index, 1);
		float x = (.) Lua.ToNumber(state, -1);

		Lua.GetRawI(state, index - 1, 2);
		float y = (.) Lua.ToNumber(state, -1);

		Lua.GetRawI(state, index - 2, 3);
		float z = (.) Lua.ToNumber(state, -1);

		Lua.GetRawI(state, index - 3, 4);
		float w = (.) Lua.ToNumber(state, -1);

		Lua.Pop(state, 4);
		return .(x, y, z, w);
	}

	private static Mat4 GetMat4(Lua.State state, int32 index) {
		Mat4 mat = ?;

		for (int i < 16) {
			Lua.GetRawI(state, index, i + 1);
			mat.floats[i] = (.) Lua.ToNumber(state, -1);
			Lua.Pop(state);
		}

		return mat;
	}

	private static void GetVec3Field(Lua.State state, int32 index, char8* name, ref Vec3f v) {
		if (Lua.GetField(state, index, name) == .Table) v = GetVec3(state, -1);
		Lua.Pop(state);
	}

	private static void GetQuaternionField(Lua.State state, int32 index, char8* name, ref Quaternion v) {
		if (Lua.GetField(state, index, name) == .Table) v = GetQuaternion(state, -1);
		Lua.Pop(state);
	}

	private static void GetMat4Field(Lua.State state, int32 index, char8* name, ref Mat4 v) {
		if (Lua.GetField(state, index, name) == .Table) v = GetMat4(state, -1);
		Lua.Pop(state);
	}

	private static Material GetMaterial(Lua.State state, int32 index) {
		/*Vec3 albedo = .(1, 1, 1);
		Vec3 specular = .(1, 1, 1);
		float smoothness = 0;
		float specularProbability = 0;
		uint32 textureIndex = 0;
		Vec3 emission = .ZERO;

		GetVec3Field(state, index, "albedo", ref albedo);
		GetVec3Field(state, index, "specular", ref specular);
		GetFloatField(state, index, "smoothness", ref smoothness);
		GetFloatField(state, index, "specular_probability", ref specularProbability);
		GetUint32Field(state, index, "texture_index", ref textureIndex);
		GetVec3Field(state, index, "emission", ref emission);
		
		return .(albedo, specular, smoothness, specularProbability, textureIndex, emission);*/

		return .();
	}

	private static MeshTransform GetMeshTransform(Lua.State state, int32 index) {
		Vec3f position = .ZERO;
		Quaternion rotation = .();
		Vec3f scale = .(1, 1, 1);
		Mat4 originMatrix = .Identity();
		Mat4 directionMatrix = .Identity();

		GetVec3Field(state, index, "translation", ref position);
		GetQuaternionField(state, index, "rotation", ref rotation);
		GetVec3Field(state, index, "scale", ref scale);
		GetMat4Field(state, index, "origin_matrix", ref originMatrix);
		GetMat4Field(state, index, "direction_matrix", ref directionMatrix);

		return .(position, rotation, scale, originMatrix, directionMatrix);
	}

	public static void PushVec3(Lua.State state, Vec3f v) {
		Lua.CreateTable(state, 3);

		Lua.PushNumber(state, v.x);
		Lua.SetRawI(state, -2, 1);

		Lua.PushNumber(state, v.y);
		Lua.SetRawI(state, -2, 2);

		Lua.PushNumber(state, v.z);
		Lua.SetRawI(state, -2, 3);
	}

	public static void PushQuaternion(Lua.State state, Quaternion v) {
		Lua.CreateTable(state, 3);

		Lua.PushNumber(state, v.x);
		Lua.SetRawI(state, -2, 1);

		Lua.PushNumber(state, v.y);
		Lua.SetRawI(state, -2, 2);

		Lua.PushNumber(state, v.z);
		Lua.SetRawI(state, -2, 3);

		Lua.PushNumber(state, v.w);
		Lua.SetRawI(state, -2, 4);
	}

	public static void PushMat4(Lua.State state, Mat4 mat) {
		Lua.CreateTable(state, 16);

		for (int i < 16) {
			Lua.PushNumber(state, mat.floats[i]);
			Lua.SetRawI(state, -2, i + 1);
		}
	}

	public static void PushMeshTransform(Lua.State state, MeshTransform transform) {
		Lua.CreateTable(state, 0, 5);

		PushVec3(state, transform.position);
		Lua.SetField(state, -2, "translation");

		PushQuaternion(state, transform.rotation);
		Lua.SetField(state, -2, "rotation");

		PushVec3(state, transform.scale);
		Lua.SetField(state, -2, "scale");

		PushMat4(state, transform.originMatrix);
		Lua.SetField(state, -2, "origin_matrix");

		PushMat4(state, transform.directionMatrix);
		Lua.SetField(state, -2, "direction_matrix");
	}
}