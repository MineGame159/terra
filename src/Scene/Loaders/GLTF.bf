using System;
using System.IO;
using System.Collections;

using StbImageBeef;
using Hebron.Runtime;

using Terra.Math;
using Terra.Json;
using Terra.Profiler;

namespace Terra.Scene.Loaders;

class Gltf {
	public Buffer[] buffers ~ DeleteContainerAndItems!(_);
	public BufferView[] bufferViews ~ DeleteContainerAndItems!(_);

	public Accessor[] accessors ~ DeleteContainerAndItems!(_);
	
	public Image[] images ~ DeleteContainerAndItems!(_);
	public Sampler[] samplers ~ DeleteContainerAndItems!(_);
	public Texture[] textures ~ DeleteContainerAndItems!(_);
	public Material[] materials ~ DeleteContainerAndItems!(_);

	public Mesh[] meshes ~ DeleteContainerAndItems!(_);

	public Camera[] cameras ~ DeleteContainerAndItems!(_);

	public Node[] nodes ~ DeleteContainerAndItems!(_);

	public Scene[] scenes ~ DeleteContainerAndItems!(_);
	public Scene scene;

	public class Buffer {
		public List<uint8> data ~ delete _;

		public this(int size) {
			this.data = new .(size);
		}
	}

	public class BufferView {
		public Buffer buffer;
		public uint32 offset, length;

		public uint8* Ptr => &buffer.data[offset];
		public Span<uint8> Span => .(Ptr, length);

		public T Get<T>(uint i) => ((T*) Ptr)[i];
	}

	public class Accessor {
		public BufferView view;
		public ComponentType componentType;
		public int count;
		public ElementType type;
	}

	public class Image {
		public String name;

		public int width, height;
		public uint8* data ~ CRuntime.free(_);

		[AllowAppend]
		public this(StringView name) {
			String _name = append .(name);
			this.name = _name;
		}
	}

	public class Sampler {
		public MagFilter mag = .Nearest;
		public MinFilter min = .Nearest;

		public Wrap wrapS = .Repeat;
		public Wrap wrapT = .Repeat;
	}

	public class Texture {
		public Image image;
		public Sampler sampler;
	}

	public struct PbrMetallicRoughness {
		public Texture baseColorTexture;
		public Texture metallicRoughnessTexture;

		public Vec4f baseColorFactor;
		public float metallicFactor;
		public float roughnessFactor;
	}

	public struct Specular {
		public Texture texture;
		public Texture colorTexture;

		public float factor;
		public Vec3f colorFactor;
	}

	public struct Clearcoat {
		public Texture texture;
		public Texture roughnessTexture;
		public Texture normalTexture;

		public float factor;
		public float roughnessFactor;
	}

	public struct Ior {
		public float ior;
	}

	public struct Emission {
		public Texture texture;
		public Vec3f factor;
		public float strength;
	}

	public class Material {
		public String name;

		public PbrMetallicRoughness? pbrMetallicRoughness;
		public Specular? specular;
		public Clearcoat? clearcoat;
		public Ior? ior;
		public Emission? emission;

		public Texture normalTexture;
		public Texture occlusionTexture;

		[AllowAppend]
		public this(StringView name) {
			String _name = append .(name);
			this.name = _name;
		}
	}

	public class Mesh {
		public String name;
		public Primitive[] primitives;

		[AllowAppend]
		public this(StringView name, int primitiveCount) {
			String _name = append .(name);
			Primitive[] _primitives = append .[primitiveCount];

			this.name = _name;
			this.primitives = _primitives;
		}

		public ~this() {
			for (let primitive in primitives)
				delete primitive;
		}

		protected override void GCMarkMembers() {
			for (let primitive in primitives)
				GC.Mark(primitive);
		}
	}

	public class Primitive {
		public Dictionary<String, Accessor> attributes ~ DeleteDictionaryAndKeys!(_);
		public Accessor indices;
		public Material material;
		public Mode mode;

		public this(int attributeCount) {
			this.attributes = new .((.) attributeCount);
		}
	}

	public class Camera {
		public String name;

		public double aspectRatio;
		public double yFov;
		public double zFar;
		public double zNear;

		[AllowAppend]
		public this(StringView name) {
			String _name = append .(name);
			this.name = _name;
		}
	}

	public class Node {
		public String name;

		public Vec3d translation;
		public Quaternion rotation;
		public Vec3d scale;

		public Node[] children;

		public Camera camera;
		public Mesh mesh;

		[AllowAppend]
		public this(StringView name, int childrenCount) {
			String _name = append .(name);
			Node[] _children = append .[childrenCount];

			this.name = _name;
			this.children = _children;
		}
	}

	public class Scene {
		public String name;
		public Node[] nodes;

		[AllowAppend]
		public this(StringView name, int nodeCount) {
			String _name = append .(name);
			Node[] _nodes = append .[nodeCount];

			this.name = _name;
			this.nodes = _nodes;
		}
	}

	public enum ComponentType {
		I8,
		U8,
		I16,
		U16,
		U32,
		F32
	}

	public enum ElementType {
		Scalar,
		Vec2,
		Vec3,
		Vec4,
		Mat2,
		Mat3,
		Mat4
	}

	public enum MagFilter {
		Nearest,
		Linear
	}

	public enum MinFilter {
		Nearest,
		Linear,
		NearestMipmapNearest,
		LinearMipmapNearest,
		NearestMipmapLinear,
		LinearMipmapLinear
	}

	public enum Wrap {
		ClampToEdge,
		MirroredRepeat,
		Repeat
	}

	public enum AlphaMode {
		Opaque,
		Mask,
		Blend
	}

	public enum Mode {
		Points,
		Lines,
		LineLoop,
		LineStrip,
		Triangles,
		TriangleStrip,
		TriangleFan
	}

	// Parse

	[Profile]
	public static Result<Gltf> Parse(StringView path) {
		FileStream fs = scope .();
		if (fs.Open(path, .Read, .Read) case .Err) return .Err;

		JsonTree tree = null;
		uint8[] binaryChunk = null;

		if (path.EndsWith(".gltf"))
			tree = JsonParser.Parse(fs).GetOrPropagate!();
		else if (path.EndsWith(".glb"))
			ParseGlb(fs, ref tree, ref binaryChunk).GetOrPropagate!();
		else
			return .Err;

		Json json = tree.root;

		Gltf gltf = new .();

		defer {
			delete tree;
			delete binaryChunk;

			if (@return == .Err) delete gltf;
		}

		StringView folder = Path.GetDirectoryPath(path, .. scope .());

		ParseBuffers(gltf, json["buffers"], folder, binaryChunk).GetOrPropagate!();
		ParseBufferViews(gltf, json["bufferViews"]).GetOrPropagate!();
		ParseAccessors(gltf, json["accessors"]).GetOrPropagate!();
		ParseImages(gltf, json["images"], folder).GetOrPropagate!();
		ParseSamplers(gltf, json["samplers"]).GetOrPropagate!();
		ParseTextures(gltf, json["textures"]).GetOrPropagate!();
		ParseMaterials(gltf, json["materials"]).GetOrPropagate!();
		ParseMeshes(gltf, json["meshes"]).GetOrPropagate!();
		ParseCameras(gltf, json["cameras"]).GetOrPropagate!();
		ParseNodes(gltf, json["nodes"]).GetOrPropagate!();
		ParseScenes(gltf, json["scenes"]).GetOrPropagate!();

		if (json.Contains("scene"))
			gltf.scene = gltf.scenes[(.) json["scene"].AsNumber];

		return gltf;
	}

	[Profile]
	private static Result<void> ParseGlb(FileStream fs, ref JsonTree tree, ref uint8[] binaryChunk) {
		uint32 magic = fs.Read<uint32>().GetOrPropagate!();
		uint32 version = fs.Read<uint32>().GetOrPropagate!();
		fs.Read<uint32>().GetOrPropagate!(); // length

		if (magic != 0x46546C67) return .Err;
		if (version != 2) return .Err;

		// JSON chunk
		{
			uint32 chunkLength = fs.Read<uint32>().GetOrPropagate!();
			uint32 chunkType = fs.Read<uint32>().GetOrPropagate!();

			if (chunkType != 0x4E4F534A) return .Err;

			if (chunkLength % 4 != 0) {
				Internal.FatalError("");
			}

			uint8[] chunkData = new .[chunkLength];
			defer delete chunkData;

			switch (fs.TryRead(chunkData)) {
			case .Ok(let val):
				if (val != chunkLength) return .Err;
			case .Err:
				return .Err;
			}

			tree = JsonParser.Parse(scope SpanMemoryStream(chunkData)).GetOrPropagate!();
		}

		// Binary chunk
		{
			uint32 chunkLength = fs.Read<uint32>().GetOrPropagate!();
			uint32 chunkType = fs.Read<uint32>().GetOrPropagate!();

			if (chunkType != 0x004E4942) return .Err;

			binaryChunk = new .[chunkLength];

			switch (fs.TryRead(binaryChunk)) {
			case .Ok(let val):
				if (val != chunkLength) return .Err;
			case .Err:
				return .Err;
			}
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseBuffers(Gltf gltf, Json json, StringView folder, uint8[] binaryChunk) {
		if (json.IsArray) {
			gltf.buffers = new .[json.AsArray.Count];
	
			for (let bufferJson in json.AsArray) {
				int length = (.) bufferJson["byteLength"].AsNumber;
				Buffer buffer = new .(length);

				if (bufferJson.Contains("uri")) {
					StringView input = bufferJson["uri"].AsString;
	
					if (input.StartsWith("data:")) {
						input = input.Substring(bufferJson["uri"].AsString.IndexOf(',') + 1);
		
						if (Base64.Decode(input, buffer.data) case .Err) {
							delete buffer;
							return .Err;
						}
					}
					else {
						StringView path = Path.InternalCombine(.. scope .(), folder, input);
	
						if (File.ReadAll(path, buffer.data) case .Err)
							return .Err;
					}
				}
				else {
					if (binaryChunk == null || @bufferJson.Index != 0 || length != binaryChunk.Count)
						return .Err;

					buffer.data.[Friend]mSize += (.) binaryChunk.Count;
					binaryChunk.CopyTo(buffer.data);
				}
	
				gltf.buffers[@bufferJson.Index] = buffer;
			}
		}
		else {
			gltf.buffers = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseBufferViews(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.bufferViews = new .[json.AsArray.Count];
	
			for (let viewJson in json.AsArray) {
				BufferView view = new .();
	
				view.buffer = gltf.buffers[(.) viewJson["buffer"].AsNumber];
				view.offset = (.) viewJson["byteOffset"].AsNumber;
				view.length = (.) viewJson["byteLength"].AsNumber;
	
				gltf.bufferViews[@viewJson.Index] = view;
			}
		}
		else {
			gltf.bufferViews = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseAccessors(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.accessors = new .[json.AsArray.Count];
	
			for (let accessorJson in json.AsArray) {
				Accessor accessor = new .();
	
				accessor.view = gltf.bufferViews[(.) accessorJson["bufferView"].AsNumber];
	
				switch ((int) accessorJson["componentType"].AsNumber) {
				case 5120:	accessor.componentType = .I8;
				case 5121:	accessor.componentType = .U8;
				case 5122:	accessor.componentType = .U16;
				case 5123:	accessor.componentType = .I16;
				case 5125:	accessor.componentType = .U32;
				case 5126:	accessor.componentType = .F32;
				}
	
				accessor.count = (.) accessorJson["count"].AsNumber;
	
				switch (accessorJson["type"].AsString) {
				case "SCALAR":	accessor.type = .Scalar;
				case "VEC2":	accessor.type = .Vec2;
				case "VEC3":	accessor.type = .Vec3;
				case "VEC4":	accessor.type = .Vec4;
				case "MAT2":	accessor.type = .Mat2;
				case "MAT3":	accessor.type = .Mat3;
				case "MAT4":	accessor.type = .Mat4;
				}
	
				gltf.accessors[@accessorJson.Index] = accessor;
			}
		}
		else {
			gltf.accessors = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseImages(Gltf gltf, Json json, StringView folder) {
		if (json.IsArray) {
			gltf.images = new .[json.AsArray.Count];
	
			for (let imageJson in json.AsArray) {
				Image image = new .(imageJson["name"].AsString);
	
				int32 width = 0;
				int32 height = 0;
				ColorComponents comp = .Default;
	
				if (imageJson.Contains("bufferView")) {
					BufferView view = gltf.bufferViews[(.) imageJson["bufferView"].AsNumber];
	
					image.data = ImageResult.RawFromStream(scope SpanMemoryStream(view.Span), .RedGreenBlueAlpha, out width, out height, out comp);
				}
				else if (imageJson.Contains("uri")) {
					StringView path = Path.InternalCombine(.. scope .(), folder, imageJson["uri"].AsString);

					FileStream fs = scope .();

					if (fs.Open(path, .Read, .Read) case .Err)
						return .Err;
					
					image.data = ImageResult.RawFromStream(fs, .RedGreenBlueAlpha, out width, out height, out comp);
				}
				else {
					return .Err;
				}
	
				if (image.data == null) {
					delete image;
					return .Err;
				}

				image.width = width;
				image.height = height;
	
				gltf.images[@imageJson.Index] = image;
			}
		}
		else {
			gltf.images = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseSamplers(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.samplers = new .[json.AsArray.Count];
	
			for (let samplerJson in json.AsArray) {
				Sampler sampler = new .();
	
				if (samplerJson.Contains("magFilter")) {
					switch ((int) samplerJson["magFilter"].AsNumber) {
					case 9728:	sampler.mag = .Nearest;
					case 9729:	sampler.mag = .Linear;
					}
				}
	
				if (samplerJson.Contains("minFilter")) {
					switch ((int) samplerJson["minFilter"].AsNumber) {
					case 9728:	sampler.min = .Nearest;
					case 9729:	sampler.min = .Linear;
					case 9984:	sampler.min = .NearestMipmapNearest;
					case 9985:	sampler.min = .LinearMipmapNearest;
					case 9986:	sampler.min = .NearestMipmapLinear;
					case 9987:	sampler.min = .LinearMipmapLinear;
					}
				}
	
				if (samplerJson.Contains("wrapS")) {
					switch ((int) samplerJson["wrapS"].AsNumber) {
					case 33071:	sampler.wrapS = .ClampToEdge;
					case 33648:	sampler.wrapS = .MirroredRepeat;
					case 10497:	sampler.wrapS = .Repeat;
					}
				}
	
				if (samplerJson.Contains("wrapT")) {
					switch ((int) samplerJson["wrapT"].AsNumber) {
					case 33071:	sampler.wrapT = .ClampToEdge;
					case 33648:	sampler.wrapT = .MirroredRepeat;
					case 10497:	sampler.wrapT = .Repeat;
					}
				}
	
				gltf.samplers[@samplerJson.Index] = sampler;
			}
		}
		else {
			gltf.samplers = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseTextures(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.textures = new .[json.AsArray.Count];
	
			for (let textureJson in json.AsArray) {
				Texture texture = new .();
	
				texture.image = gltf.images[(.) textureJson["source"].AsNumber];
				texture.sampler = gltf.samplers[(.) textureJson["sampler"].AsNumber];
	
				gltf.textures[@textureJson.Index] = texture;
			}
		}
		else {
			gltf.textures = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseMaterials(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.materials = new .[json.AsArray.Count];
	
			for (let materialJson in json.AsArray) {
				Material material = new .(materialJson["name"].AsString);
	
				// PBR metallic roughness
				if (materialJson.Contains("pbrMetallicRoughness")) {
					Json j = materialJson["pbrMetallicRoughness"];
					PbrMetallicRoughness v = .();
	
					GetTexture(gltf, j, "baseColorTexture", out v.baseColorTexture);
					GetTexture(gltf, j, "metallicRoughnessTexture", out v.metallicRoughnessTexture);
	
					GetVec(j, "baseColorFactor", out v.baseColorFactor, .(1));
					GetFloat(j, "metallicFactor", out v.metallicFactor, 1);
					GetFloat(j, "roughnessFactor", out v.roughnessFactor, 1);
	
					material.pbrMetallicRoughness = v;
				}
	
				// Emission
				Emission GetEmission() {
					if (!material.emission.HasValue) {
						material.emission = .() {
							texture = null,
							factor = .(1),
							strength = 1
						};
					}
	
					return material.emission.Value;
				}
	
				if (materialJson.Contains("emissiveTexture")) {
					Emission v = GetEmission();
	
					GetTexture(gltf, materialJson, "emissiveTexture", out v.texture);
	
					material.emission = v;
				}
	
				if (materialJson.Contains("emissiveFactor")) {
					Emission v = GetEmission();
	
					GetVec<3>(materialJson, "emissiveFactor", out v.factor, .(1));
					
					material.emission = v;
				}
	
				// Other textures
				GetTexture(gltf, materialJson, "normalTexture", out material.normalTexture);
				GetTexture(gltf, materialJson, "occlusionTexture", out material.occlusionTexture);
	
				// Extensions
				if (materialJson.Contains("extensions")) {
					for (let (name, j) in materialJson["extensions"].AsObject) {
						switch (name.String) {
						// Specular
						case "KHR_materials_specular":
							Specular v = .();
	
							GetTexture(gltf, j, "specularTexture", out v.texture);
							GetTexture(gltf, j, "specularColorTexture", out v.colorTexture);
	
							GetFloat(j, "specularFactor", out v.factor, 1);
							GetVec<3>(j, "specularColorFactor", out v.colorFactor, .(1));
	
							material.specular = v;
	
						// Clearcoat
						case "KHR_materials_clearcoat":
							Clearcoat v = .();
	
							GetTexture(gltf, j, "clearcoatTexture", out v.texture);
							GetTexture(gltf, j, "clearcoatRoughnessTexture", out v.roughnessTexture);
							GetTexture(gltf, j, "clearcoatNormalTexture", out v.normalTexture);
	
							GetFloat(j, "clearcoatFactor", out v.factor, 1);
							GetFloat(j, "clearcoatRoughnessFactor", out v.roughnessFactor, 1);
								
							material.clearcoat = v;
	
						// IOR
						case "KHR_materials_ior":
							Ior v = .();
	
							GetFloat(j, "ior", out v.ior, 1.5f);
	
							material.ior = v;
	
						// Emissive strength
						case "KHR_materials_emissive_strength":
							Emission v = GetEmission();
	
							GetFloat(j, "emissiveStrength", out v.strength, 1);
	
							material.emission = v;
						}
					}
				}
	
				gltf.materials[@materialJson.Index] = material;
			}
		}
		else {
			gltf.materials = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseMeshes(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.meshes = new .[json.AsArray.Count];
	
			for (let meshJson in json.AsArray) {
				Mesh mesh = new .(meshJson["name"].AsString, meshJson["primitives"].AsArray.Count);
	
				for (let primitiveJson in meshJson["primitives"].AsArray) {
					Primitive primitive = new .(primitiveJson["attributes"].AsObject.Count);
	
					for (let (name, index) in primitiveJson["attributes"].AsObject) {
						primitive.attributes[new .(name)] = gltf.accessors[(.) index.AsNumber];
					}
	
					GetRef(gltf.accessors, primitiveJson, "indices", out primitive.indices);
					GetRef(gltf.materials, primitiveJson, "material", out primitive.material);
	
					int modeI;
					GetInt(primitiveJson, "mode", out modeI, 4);
					primitive.mode = (.) modeI;
	
					mesh.primitives[@primitiveJson.Index] = primitive;
				}
	
				gltf.meshes[@meshJson.Index] = mesh;
			}
		}
		else {
			gltf.meshes = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseCameras(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.cameras = new .[json.AsArray.Count];
	
			for (let cameraJson in json.AsArray) {
				if (cameraJson["type"].AsString != "perspective") continue;
	
				Json j = cameraJson["perspective"];
				Camera camera = new .(cameraJson["name"].AsString);
	
				GetDouble(j, "aspectRatio", out camera.aspectRatio, 0);
				GetDouble(j, "yfov", out camera.yFov, 0);
				GetDouble(j, "zfar", out camera.zFar, 0);
				GetDouble(j, "znear", out camera.zNear, 0);
	
				gltf.cameras[@cameraJson.Index] = camera;
			}
		}
		else {
			gltf.cameras = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseNodes(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.nodes = new .[json.AsArray.Count];
	
			for (let nodeJson in json.AsArray) {
				int childrenCount = 0;
	
				if (nodeJson.Contains("children")) {
					childrenCount = nodeJson["children"].AsArray.Count;
				}
	
				Node node = new .(nodeJson["name"].AsString, childrenCount);
	
				if (nodeJson.Contains("translation")) {
					Json j = nodeJson["translation"];
					node.translation = .(j[0].AsNumber, j[1].AsNumber, j[2].AsNumber);
				}
	
				if (nodeJson.Contains("rotation")) {
					Json j = nodeJson["rotation"];
					node.rotation = .((.) j[0].AsNumber, (.) j[1].AsNumber, (.) j[2].AsNumber, (.) j[3].AsNumber);
				}
	
				if (nodeJson.Contains("scale")) {
					Json j = nodeJson["scale"];
					node.scale = .(j[0].AsNumber, j[1].AsNumber, j[2].AsNumber);
				}
				else {
					node.scale = .(1);
				}
	
				GetRef(gltf.cameras, nodeJson, "camera", out node.camera);
				GetRef(gltf.meshes, nodeJson, "mesh", out node.mesh);
	
				gltf.nodes[@nodeJson.Index] = node;
			}
	
			// Children
			for (let nodeJson in json.AsArray) {
				Node node = gltf.nodes[@nodeJson.Index];
	
				if (nodeJson.Contains("children")) {
					for (let childJson in nodeJson["children"].AsArray) {
						node.children[@childJson.Index] = gltf.nodes[(.) childJson.AsNumber];
					}
				}
			}
		}
		else {
			gltf.nodes = new .[0];
		}

		return .Ok;
	}
	
	[Profile]
	private static Result<void> ParseScenes(Gltf gltf, Json json) {
		if (json.IsArray) {
			gltf.scenes = new .[json.AsArray.Count];
	
			for (let sceneJson in json.AsArray) {
				int nodeCount = 0;
				
				if (sceneJson.Contains("nodes")) {
					nodeCount = sceneJson["nodes"].AsArray.Count;
				}
	
				Scene scene = new .(sceneJson["name"].AsString, nodeCount);
	
				if (sceneJson.Contains("nodes")) {
					for (let nodeJson in sceneJson["nodes"].AsArray) {
						scene.nodes[@nodeJson.Index] = gltf.nodes[(.) nodeJson.AsNumber];
					}
				}
				else {
					scene.nodes = new .[0];
				}
	
				gltf.scenes[@sceneJson.Index] = scene;
			}
		}
		else {
			gltf.scenes = new .[0];
		}

		return .Ok;
	}

	private static void GetInt(Json json, StringView name, out int v, int defaultValue) {
		if (json.Contains(name)) {
			v = (.) json[name].AsNumber;
		}
		else {
			v = defaultValue;
		}
	}

	private static void GetFloat(Json json, StringView name, out float v, float defaultValue) {
		if (json.Contains(name)) {
			v = (.) json[name].AsNumber;
		}
		else {
			v = defaultValue;
		}
	}

	private static void GetDouble(Json json, StringView name, out double v, double defaultValue) {
		if (json.Contains(name)) {
			v = json[name].AsNumber;
		}
		else {
			v = defaultValue;
		}
	}

	private static void GetVec<C>(Json json, StringView name, out Vec<float, C> v, Vec<float, C> defaultValue) where C : const int {
		if (json.Contains(name)) {
			float[C] values = ?;
	
			for (let valueJson in json[name].AsArray) {
				values[@valueJson.Index] = (.) valueJson.AsNumber;
			}
	
			v = .(values);
		}
		else {
			v = defaultValue;
		}
	}

	private static void GetTexture(Gltf gltf, Json json, StringView name, out Texture v) {
		if (json.Contains(name)) {
			v = gltf.textures[(.) json[name]["index"].AsNumber];
		}
		else {
			v = null;
		}
	}

	private static void GetRef<T>(T[] array, Json json, StringView name, out T v) where T : class {
		if (json.Contains(name)) {
			v = array[(.) json[name].AsNumber];
		}
		else {
			v = null;
		}
	}

	public class NodeEnumerator : IEnumerator<(Node, MeshTransform)> {
		struct Entry {
			public Node node;
			public MeshTransform transform;

			public this(Node node, MeshTransform transform) {
				this.node = node;
				this.transform = transform;
			}
		}

		private bool meshOnly;

		private append List<Entry> entries = .(16);

		public this(Scene scene, bool meshOnly) {
			this.meshOnly = meshOnly;

			for (let node in scene.nodes) {
				entries.Add(.(node, .(.ZERO, .(), .(1, 1, 1))));
			}
		}

		public Result<(Node, MeshTransform)> GetNext() {
			while (true) {
				switch (GetNextNode()) {
				case .Ok(let val):
					if (!meshOnly || val.0.mesh != null) {
						return (val.0, val.1);
					}
				case .Err:
					return .Err;
				}
			}
		}

		private Result<(Node, MeshTransform)> GetNextNode() {
			if (entries.IsEmpty) return .Err;

			Entry entry = entries.PopBack();

			Vec3f translation = .((.) entry.node.translation.x, (.) entry.node.translation.y, (.) entry.node.translation.z);
			Quaternion rotation = entry.node.rotation;
			Vec3f scale = .((.) entry.node.scale.x, (.) entry.node.scale.y, (.) entry.node.scale.z);

			MeshTransform globalTransform = entry.transform;

			globalTransform.originMatrix = globalTransform.originMatrix.Translate(translation);
			globalTransform.originMatrix = globalTransform.originMatrix * rotation.Matrix.Transpose();
			globalTransform.originMatrix = globalTransform.originMatrix.Scale(scale);
			
			globalTransform.directionMatrix = globalTransform.directionMatrix * rotation.Matrix.Transpose();
			globalTransform.directionMatrix = globalTransform.directionMatrix.Scale(scale);

			for (let child in entry.node.children) {
				entries.Add(.(child, globalTransform));
			}

			return (entry.node, globalTransform);
		}
	}
}