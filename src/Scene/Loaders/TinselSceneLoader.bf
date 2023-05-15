using System;
using System.IO;
using System.Collections;

using StbImageBeef;

using Terra.Math;
using Terra.Profiler;

namespace Terra.Scene.Loaders;

class TinselSceneLoader : ISceneLoader {
	private static char8[] WHITESPACE = new .(' ', '\t') ~ delete _;

	private append String path = .();
	private append String folderPath = .();

	private StreamReader reader;
	private append String line = .(128);

	private Dictionary<String, uint32> textureIds = new .() ~ DeleteDictionaryAndKeys!(_);
	private Dictionary<String, uint32> materialIds = new .() ~ DeleteDictionaryAndKeys!(_);

	public this(StringView path) {
		this.path.Set(path);
	}

	[Profile]
	public Result<void> Load(ISceneBuilder scene) {
		Path.GetDirectoryPath(path, folderPath).GetOrPropagate!();

		reader = scope .();
		if (reader.Open(path) case .Err) return .Err;

		for (Lines) {
			int spaceI = line.IndexOf(' ');

			if (spaceI == -1) {
				switch (line) {
				case "camera":	ParseCamera(scene).GetOrPropagate!();
				case "mesh":	ParseMesh(scene).GetOrPropagate!();
				case "{":		EmptyConstruct!(false);
				default:		EmptyConstruct!();
				}
			}
			else {
				StringView construct = line[...(spaceI - 1)];
				StringView name = line[(spaceI + 1)...];

				if (construct == "material") ParseMaterial(scene, name).GetOrPropagate!();
				else EmptyConstruct!();
			}
		}

		return .Ok;
	}

	[Profile]
	private Result<void> ParseCamera(ISceneBuilder scene) {
		Expect!("{");

		Vec3f position = .(1);
		Vec3f lookAt = .ZERO;
		float fov = 75;

		for (Lines) {
			if (line == "}") break;

			StringSplitEnumerator split = line.Split(WHITESPACE, .RemoveEmptyEntries);
			StringView field = split.GetNext().GetOrPropagate!();

			switch (field) {
			case "position":	position = ParseVec3!(split);
			case "lookat":		lookAt = ParseVec3!(split);
			case "fov":			fov = ParseFloat!(split);
			}
		}

		scene.SetCamera(position, lookAt, fov);
		return .Ok;
	}
	
	[Profile]
	private Result<void> ParseMaterial(ISceneBuilder scene, StringView name) {
		String name_ = new String(name);

		defer {
			if (@return == .Err)
				delete name_;
		}

		Expect!("{");

		Material material = .();
		material.albedo = .(0.8f, 0.8f, 0.8f, 0);

		for (Lines) {
			if (line == "}") break;

			StringSplitEnumerator split = line.Split(WHITESPACE, .RemoveEmptyEntries);
			StringView field = split.GetNext().GetOrPropagate!();

			switch (field) {
			case "color":				material.albedo = ParseVec3!(split);
			case "emission":			material.emission = ParseVec3!(split);
			case "metallic":			material.metallic = ParseFloat!(split);
			case "subsurface":			material.subsurface = ParseFloat!(split);
			case "roughness":			material.roughness = ParseFloat!(split);
			case "speculartint":		material.specularTint = ParseFloat!(split);
			case "sheen":				material.sheen = ParseFloat!(split);
			case "sheentint":			material.sheenTint = ParseFloat!(split);
			case "clearcoat":			material.clearcoat = ParseFloat!(split);
			case "clearcoatgloss":		material.clearcoatRoughness = ParseFloat!(split);
			case "spectrans":			material.specTrans = ParseFloat!(split);
			case "anisotropic":			material.anisotropic = ParseFloat!(split);
			case "ior":					material.ior = ParseFloat!(split);

			case "albedotexture":				material.albedoTexture = GetTexture(scene, split.GetNext().GetOrPropagate!()).GetOrPropagate!();
			case "metallicroughnesstexture":	material.metallicRoughnessTexture = GetTexture(scene, split.GetNext().GetOrPropagate!()).GetOrPropagate!();
			case "emissiontexture":				material.emissionTexture = GetTexture(scene, split.GetNext().GetOrPropagate!()).GetOrPropagate!();
			case "normaltexture":				material.normalTexture = GetTexture(scene, split.GetNext().GetOrPropagate!()).GetOrPropagate!();
			}
		}

		materialIds[name_] = scene.CreateMaterial(material);
		return .Ok;
	}

	[Profile]
	private Result<uint32> GetTexture(ISceneBuilder scene, StringView name) {
		if (name == "none") return 0;

		// Check cache
		uint32 textureId;

		if (textureIds.TryGetValueAlt(name, out textureId))
			return textureId + 1;

		// Create
		String path = scope .(64);
		Path.InternalCombine(path, folderPath, name);

		FileStream fs = scope .();
		if (fs.Open(path, .Read, .Read) case .Err) return .Err;

		ImageResult image = ImageResult.FromStream(fs, .RedGreenBlueAlpha);
		defer delete image;

		uint32 imageId = scene.CreateImage(image.Width, image.Height, image.Data).GetOrPropagate!();
		textureId = scene.CreateTexture(imageId, .Linear, .Linear);

		textureIds[new .(name)] = textureId;
		return textureId + 1;
	}
	
	[Profile]
	private Result<void> ParseMesh(ISceneBuilder scene) {
		Expect!("{");

		String objPath = scope .(64);
		uint32 materialId = 0;

		Vec3f position = .ZERO;
		Quaternion rotation = .();
		Vec3f scale = .(1);

		for (Lines) {
			if (line == "}") break;

			StringSplitEnumerator split = line.Split(WHITESPACE, .RemoveEmptyEntries);
			StringView field = split.GetNext().GetOrPropagate!();

			switch (field) {
			case "file":
				StringView file = split.GetNext().GetOrPropagate!();
				Path.InternalCombine(objPath, folderPath, file);

			case "material":
				StringView name = split.GetNext().GetOrPropagate!();

				if (!materialIds.TryGetValueAlt(name, out materialId))
					return .Err;

				materialId++;

			case "position":	position = ParseVec3!(split);
			case "rotation":	rotation = ParseQuat!(split);
			case "scale":		scale = ParseVec3!(split);
			}
		}

		if (objPath.IsEmpty || materialId == 0)
			return .Err;

		ObjMeshLoader obj = scope .(objPath, materialId - 1);
		obj.Parse().GetOrPropagate!();

		uint32 meshId;
		
		using (let mesh = scene.CreateMesh(obj.TriangleCount, out meshId)) {
			obj.Load(mesh).GetOrPropagate!();
		}

		scene.AddMesh(meshId, .(position, rotation, scale));
		return .Ok;
	}

	private mixin EmptyConstruct(bool openingBrace = true) {
		if (openingBrace)
			Expect!("{");

		for (Lines) {
			if (line == "}") break;
		}
	}

	private LineEnumerator Lines => .(reader, line);

	private mixin Expect(StringView expected) {
		line.Clear();

		if (reader.ReadLine(line) == .Err)
			return .Err;

		if (line != expected)
			return .Err;
	}

	private mixin ParseFloat(StringSplitEnumerator split) {
		float.Parse(split.GetNext().GetOrPropagate!()).GetOrPropagate!()
	}

	private mixin ParseVec3(StringSplitEnumerator split) {
		Vec3f(ParseFloat!(split), ParseFloat!(split), ParseFloat!(split))
	}

	private mixin ParseQuat(StringSplitEnumerator split) {
		Quaternion(ParseFloat!(split), ParseFloat!(split), ParseFloat!(split), ParseFloat!(split))
	}
}