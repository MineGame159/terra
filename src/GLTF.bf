using System;
using System.Interop;
using System.Collections;
using System.Diagnostics;

namespace Nova;

static class GLTF {
	public enum Result : c_int {
		Success,
		DataTooShort,
		UnknownFormat,
		InvalidJson,
		InvalidGltf,
		InvalidOptions,
		FileNotFound,
		IoError,
		OutOfMemory,
		LegacyGlfw
	}

	public typealias AllocFn = function void*(void* user, c_size size);
	public typealias FreeFn = function void(void* user, void* ptr);

	[CRepr]
	public struct MemoryOptions {
		public AllocFn alloc;
		public FreeFn free;
		public void* user;
	}

	public typealias ReadFn = function Result(MemoryOptions* memoryOptions, FileOptions* fileOptions, char8* path, c_size* size, void** data);
	public typealias ReleaseFn = function void(MemoryOptions* memoryOptions, FileOptions* fileOptions, void* data);

	[CRepr]
	public struct FileOptions {
		public ReadFn read;
		public ReleaseFn release;
		public void* user;
	}

	public enum FileType : c_int {
		Invalid, // auto detect
		Gltf,
		Glb
	}

	[CRepr]
	public struct Options {
		public FileType fileType;
		public c_size jsonTokenCount; // 0 - auto detect
		public MemoryOptions memory;
		public FileType file;
	}

	[CRepr]
	public struct Extras {
		public c_size startOffset;
		public c_size endOffset;
		public char8* data;
	}

	[CRepr]
	public struct Extension {
		public char8* name;
		public char8* data;
	}

	[CRepr]
	public struct Asset {
		public char8* copyright;
		public char8* generator;
		public char8* version;
		public char8* minVersion;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	public enum PrimitiveType : c_int {
		Points,
		Lines,
		LineLoop,
		LineStrip,
		Triangles,
		TriangleStrip,
		TriangleFan
	}

	public enum ComponentType : c_int {
		Invalid,
		R8,
		R8u,
		R16,
		R16u,
		R32u,
		R32f
	}

	public enum Type : c_int {
		Invalid,
		Scalar,
		Vec2,
		Vec3,
		Mat2,
		Mat3,
		Mat4
	}

	public enum DataFreeMethod : c_int {
		None,
		FileRelease,
		MemoryRelease
	}

	[CRepr]
	public struct Buffer {
		public char8* name;
		public c_size size;
		public char8* uri;
		public void* data;
		public DataFreeMethod dataFreeMethod;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	public enum BufferViewType : c_int {
		Invalid,
		Indices,
		Vertices
	}

	public enum MeshoptCompressionMode : c_int {
		Invalid,
		Attributes,
		Triangles,
		Indices
	}

	public enum MeshoptCompressionFilter : c_int {
		None,
		Octahedral,
		Quaternion,
		Exponential
	}

	[CRepr]
	public struct MeshoptCompression {
		public Buffer* buffer;
		public c_size offset;
		public c_size size;
		public c_size stride;
		public c_size count;
		public MeshoptCompressionMode mode;
		public MeshoptCompressionFilter filter;
	}

	[CRepr]
	public struct BufferView {
		public char8* name;
		public Buffer* buffer;
		public c_size offset;
		public c_size size;
		public c_size stride;
		public BufferViewType type;
		public void* data;
		public c_int hasMeshoptCompression;
		public MeshoptCompression meshoptCompression;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;

		public uint8* Address => &((uint8*) buffer.data)[offset];

		public T Get<T>(uint index) => ((T*) Address)[index];
	}

	[CRepr]
	public struct AccessorSparse {
		public c_size count;
		public BufferView* indicesBufferView;
		public c_size indicesByteOffset;
		public ComponentType indicesComponentType;
		public BufferView* valuesBufferView;
		public c_size valuesByteOffset;
		public Extras extras;
		public Extras indicesExtras;
		public Extras valuesExtras;
		public c_size extensionsCount;
		public Extension* extensions;
		public c_size indicesExtensionsCount;
		public Extension* indicesExtensions;
		public c_size valuesExtensionsCount;
		public Extension* valuesExtensions;
	}

	[CRepr]
	public struct Accessor {
		public char8* name;
		public ComponentType componentType;
		public c_int normalized;
		public Type type;
		public c_size offset;
		public c_size count;
		public c_size stride;
		public BufferView* bufferView;
		public c_int hasMin;
		public float[16] min;
		public c_int hasMax;
		public float[16] max;
		public c_int isSparse;
		public AccessorSparse sparse;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Image {
		public char8* name;
		public char8* uri;
		public BufferView* bufferView;
		public char8* mimeType;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Sampler {
		public char8* name;
		public c_int magFilter;
		public c_int minFilter;
		public c_int wrapS;
		public c_int wrapT;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Texture {
		public char8* name;
		public Image* image;
		public Sampler* sampler;
		public c_int hasBasisu;
		public Image* basisuImage;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct TextureTransform {
		public float[2] offset;
		public float rotation;
		public float[2] scale;
		public c_int hasTexcoord;
		public c_int texcoord;
	}

	[CRepr]
	public struct TextureView {
		public Texture* texture;
		public c_int texcoord;
		public float scale;
		public c_int hasTransform;
		public TextureTransform transform;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct PbrMetallicRoughness {
		public TextureView baseColorTexture;
		public TextureView metallicRoughnessTexture;

		public float[4] baseColorFactor;
		public float metallicFactor;
		public float roughnessFactor;
	}

	[CRepr]
	public struct PbrSpecularGlossiness {
		public TextureView diffuseTexture;
		public TextureView specularGlossinessTexture;

		public float[4] diffuseFactor;
		public float[3] specularFactor;
		public float glossinessFactor;
	}

	[CRepr]
	public struct Clearcoat {
		public TextureView texture;
		public TextureView roughnessTexture;
		public TextureView normalTexture;

		public float factor;
		public float roughnessFactor;
	}

	[CRepr]
	public struct Ior {
		public float ior;
	}

	[CRepr]
	public struct Specular {
		public TextureView texture;
		public TextureView colorTexture;

		public float[3] colorFactor;
		public float factor;
	}

	[CRepr]
	public struct Sheen {
		public TextureView colorTexture;
		public float[3] colorFactor;

		public TextureView roughnessTexture;
		public float roughnessFactor;
	}

	[CRepr]
	public struct Transmission {
		public TextureView texture;
		public float factor;
	}

	[CRepr]
	public struct Volume {
		public TextureView thicknessTexture;
		public float thicknessFactor;
		public float[3] attenuationColor;
		public float attenuationDistance;
	}

	[CRepr]
	public struct EmissiveStrength {
		public float strength;
	}

	[CRepr]
	public struct Iridescence {
		public float factor;
		public TextureView texture;
		public float ior;
		public float thicknessMin;
		public float thicknessMax;
		public TextureView thicknessTexture;
	}

	public enum AlphaMode : c_int {
		Opaque,
		Mask,
		Blend
	}

	[CRepr]
	public struct Material {
		public char8* name;
		public c_int hasPbrMetallicRoughness;
		public c_int hasPbrSpecularGlossiness;
		public c_int hasClearcoat;
		public c_int hasTransmission;
		public c_int hasVolume;
		public c_int hasIor;
		public c_int hasSpecular;
		public c_int hasSheen;
		public c_int hasEmissiveStrength;
		public c_int hasIridescence;
		public PbrMetallicRoughness pbrMetallicRoughness;
		public PbrSpecularGlossiness pbrSpecularGlossiness;
		public Clearcoat clearcoat;
		public Ior ior;
		public Specular specular;
		public Sheen sheen;
		public Transmission transmission;
		public Volume volume;
		public EmissiveStrength emissiveStrength;
		public Iridescence iridescence;
		public TextureView normalTexture;
		public TextureView occlusionTexture;
		public TextureView emissiveTexture;
		public float[3] emissiveFactor;
		public AlphaMode alphaMode;
		public float alphaCutoff;
		public c_int doubleSided;
		public c_int unlit;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	public enum AttributeType : c_int {
		Invalid,
		Position,
		Normal,
		Tanget,
		Texcoord,
		Color,
		Joints,
		Weights,
		Custom
	}

	[CRepr]
	public struct Attribute {
		public char8* name;
		public AttributeType type;
		public c_int index;
		public Accessor* data;
	}

	[CRepr]
	public struct MorphTarget {
		public Attribute* attributes;
		public c_size attributesCount;
	}

	[CRepr]
	public struct DracoMeshCompression {
		public BufferView* bufferView;
		public Attribute* attributes;
		public c_size attributesCount;
	}

	[CRepr]
	public struct MaterialMapping {
		public c_size variant;
		public Material* material;
		public Extras extras;
	}

	[CRepr]
	public struct Primitive {
		public PrimitiveType type;
		public Accessor* indices;
		public Material* material;
		public Attribute* attributes;
		public c_size attributesCount;
		public MorphTarget* targets;
		public c_size targetsCount;
		public Extras extras;
		public c_int hasDracoMeshCompression;
		public DracoMeshCompression dracoMeshCompression;
		public MaterialMapping* mappings;
		public c_size mappingsCount;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Mesh {
		public char8* name;
		public Primitive* primitives;
		public c_size primitivesCount;
		public float* weights;
		public c_size weightsCount;
		public char8** targetNames;
		public c_size targetNamesCount;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;

		public static int GetHashCode(Mesh* mesh) {
			return Utils.CombineHashCode((.) (void*) mesh, Utils.CombineHashCode(StringView(mesh.name).GetHashCode(), (.) mesh.primitivesCount));
		}
	}

	public enum CameraType : c_int {
		Invalid,
		Perspective,
		Orthographics
	}

	[CRepr]
	public struct CameraPerspective {
		public int32 hasAspectRatio;
		public float aspectRaio;
		public float yfov;
		public c_int hasZfar;
		public float zfar;
		public float znear;
		public Extras extras;
	}

	[CRepr]
	public struct CameraOrthographic {
		public float xmag;
		public float ymag;
		public float zfar;
		public float znear;
		public Extras extras;
	}

	[CRepr, Union]
	public struct CameraData {
		public CameraPerspective perspective;
		public CameraOrthographic orthographic;
	}

	[CRepr]
	public struct Camera {
		public char8* name;
		public CameraType type;
		public CameraData data;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	public enum LightType : c_int {
		Invalid,
		Directional,
		Point,
		Spot
	}

	[CRepr]
	public struct Light {
		public char8* name;
		public float[3] color;
		public float intensity;
		public LightType type;
		public float range;
		public float spotInnerConeAngle;
		public float spotOuterConeAngle;
		public Extras extras;
	}

	[CRepr]
	public struct MeshGpuInstancing {
		public BufferView* bufferView;
		public Attribute* attributes;
		public c_size attributesCount;
	}

	[CRepr]
	public struct Node {
		public char8* name;
		public Node* parent;
		public Node** children;
		public c_size childrenCount;
		public Skin* skin;
		public Mesh* mesh;
		public Camera* camera;
		public Light* light;
		public float* weights;
		public c_size weightsCount;
		public c_int hasTranslation;
		public c_int hasRotation;
		public c_int hasScale;
		public c_int hasMatrix;
		public float[3] translation;
		public float[4] rotation;
		public float[3] scale;
		public float[16] matrix;
		public Extras extras;
		public c_int hasMeshGpuInstancing;
		public MeshGpuInstancing meshGpuInstancing;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Skin {
		public char8* name;
		public Node** joints;
		public c_size jointsCount;
		public Node* skeleton;
		public Accessor* inverseBindMatrices;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Scene {
		public char8* name;
		public Node** nodes;
		public c_size nodesCount;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	public enum InterpolationType {
		Linear,
		Step,
		CubicSpline
	}

	[CRepr]
	public struct AnimationSampler {
		public Accessor* input;
		public Accessor* output;
		public InterpolationType interpolation;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	public enum AnimationPathType {
		Invalid,
		Translation,
		Rotation,
		Scale,
		Weights
	}

	[CRepr]
	public struct AnimationChannel {
		public AnimationSampler* sampler;
		public Node* targetNode;
		public AnimationPathType targetPath;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct Animation {
		public char8* name;
		public AnimationSampler* samplers;
		public c_size samplersCount;
		public AnimationChannel* channels;
		public c_size channelsCount;
		public Extras extras;
		public c_size extensionsCount;
		public Extension* extensions;
	}

	[CRepr]
	public struct MaterialVariant {
		public char8* name;
		public Extras extras;
	}

	[CRepr]
	public struct Data {
		public FileType fileType;
		public void* fileData;

		public Asset asset;

		public Mesh* meshes;
		public c_size meshesCount;

		public Material* materials;
		public c_size materialsCount;

		public Accessor* accessors;
		public c_size accessorsCount;

		public BufferView* bufferViews;
		public c_size bufferViewsCount;

		public Buffer* buffers;
		public c_size bufersCount;

		public Image* images;
		public c_size imagesCount;

		public Texture* textures;
		public c_size texturesCount;

		public Sampler* samplers;
		public c_size samplersCount;

		public Skin* skins;
		public c_size skinsCount;

		public Camera* cameras;
		public c_size camerasCount;

		public Light* lights;
		public c_size lightsCount;

		public Node* nodes;
		public c_size nodesCount;

		public Scene* scenes;
		public c_size scenesCount;

		public Scene* scene;

		public Animation* animations;
		public c_size animationsCount;

		public MaterialVariant* variants;
		public c_size variantsCount;

		public Extras extras;

		public c_size dataExtensionsCount;
		public Extension* dataExtensions;

		public char8** extensionsUsed;
		public c_size extensionsUsedCount;

		public char8** extensionsRequired;
		public c_size extensionsRequiredCount;

		public char8* json;
		public c_size jsonSize;

		public void* bin;
		public c_size binSize;

		public MemoryOptions memory;
		public FileOptions file;
	}

	[LinkName("cgltf_parse_file")]
	public static extern Result ParseFile(Options* options, char8* path, Data** data);

	[LinkName("cgltf_free")]
	public static extern void Free(Data* data);

	[LinkName("cgltf_load_buffers")]
	public static extern Result LoadBuffers(Options* options, Data* data, char8* gltfPath);

	public static Options GetDefaultOptions() {
		return .() {
			memory = .() {
				alloc = => Alloc,
				free = => Free
			}
		};
	}

	private static void* Alloc(void* user, c_size size) => new uint8[size]*;
	private static void Free(void* user, void* ptr) { delete ptr; }

	public static Node* GetPerspectiveCameraNode(Data* data) {
		for (let (node, transform) in scope NodeEnumerator(data, false)) {
			if (node.camera != null && node.camera.type == .Perspective) {
				return node;
			}
		}

		return null;
	}

	public class NodeEnumerator : IEnumerator<(Node*, MeshTransform)> {
		struct Entry {
			public Node* node;
			public MeshTransform transform;

			public this(Node* node, MeshTransform transform) {
				this.node = node;
				this.transform = transform;
			}
		}

		private Data* data;
		private bool meshOnly;

		private append List<Entry> entries = .(16);

		public this(Data* data, bool meshOnly) {
			this.data = data;
			this.meshOnly = meshOnly;

			for (uint i < data.scene.nodesCount) {
				Node* node = data.scene.nodes[i];
				entries.Add(.(node, .(.ZERO, .(), .(1, 1, 1), .Identity(), .Identity())));
			}
		}

		public Result<(Node*, MeshTransform)> GetNext() {
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

		private Result<(Node*, MeshTransform)> GetNextNode() {
			if (entries.IsEmpty) return .Err;

			Entry entry = entries.PopBack();

			MeshTransform nodeTransform = GetTransform(entry.node);
			//MeshTransform globalTransform = Combine(entry.transform, nodeTransform);

			MeshTransform globalTransform = entry.transform;

			globalTransform.originMatrix = globalTransform.originMatrix.Translate(nodeTransform.position);
			globalTransform.originMatrix = globalTransform.originMatrix * nodeTransform.rotation.Matrix.Transpose();
			globalTransform.originMatrix = globalTransform.originMatrix.Scale(nodeTransform.scale);
			
			globalTransform.directionMatrix = globalTransform.directionMatrix * nodeTransform.rotation.Matrix.Transpose();
			globalTransform.directionMatrix = globalTransform.directionMatrix.Scale(nodeTransform.scale);

			for (uint i < entry.node.childrenCount) {
				Node* node = entry.node.children[i];
				entries.Add(.(node, globalTransform));
			}

			return (entry.node, globalTransform);
		}

		private static MeshTransform GetTransform(Node* node) {
			return .(
				.(node.translation[0], node.translation[1], node.translation[2]),
				.(node.rotation),
				.(node.scale[0], node.scale[1], node.scale[2])
			);
		}

		private static MeshTransform Combine(MeshTransform a, MeshTransform b) {
			return .(
				a.position + b.position * a.scale,
				a.rotation.Rotate(b.rotation),
				a.scale * b.scale,

				a.originMatrix * b.originMatrix,
				a.directionMatrix * b.directionMatrix
			);
		}
	}
}