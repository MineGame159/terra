using System;
using System.IO;
using System.Collections;

namespace Nova;

/*class OBJ : IEnumerable<Part> {
	public struct Triangle : this(uint32 i1, uint32 i2, uint32 i3) {}

	public class Part : IEnumerable<Triangle> {
		public Material material;

		private List<Triangle> triangles = new .() ~ delete _;

		private this(Material material) {
			this.material = material;
		}

		public List<Triangle>.Enumerator GetEnumerator() => triangles.GetEnumerator();
	}

	private List<Vec3f> vertices = new .() ~ delete _;

	private Dictionary<String, Material> materials = new .() ~ DeleteDictionaryAndKeys!(_);
	private List<Part> parts = new .() ~ DeleteContainerAndItems!(_);
	
	private this() {}

	public Vec3f GetVertex(uint32 index) => vertices[index - 1];

	public List<Part>.Enumerator GetEnumerator() => parts.GetEnumerator();
	
	public static Result<OBJ> Parse(StringView path) {
		OBJ obj = new .();

		mixin Error() {
			delete obj;
			return .Err;
		}

		mixin ParseNumber<T>(StringView string) where T : var {
			let result = T.Parse(string..Trim());
			if (result case .Err) Error!();
			
			result.Value
		}

		String folderPath = scope .();
		Path.GetDirectoryPath(path, folderPath);

		StreamReader reader = scope .();
		if (reader.Open(path) case .Err) Error!();

		Part part = null;

		for (StringView line in reader.Lines) {
			if (line.StartsWith('#')) continue;

			if (line.StartsWith("mtllib ")) {
				if (ParseMaterials(obj, scope $"{folderPath}/{line[7...]}") == .Err) Error!();
			}
			else if (line.StartsWith("v ")) {
				StringSplitEnumerator split = line[2...].Split(' ', .RemoveEmptyEntries);

				obj.vertices.Add(.(
					ParseNumber!<float>(split.GetNext()),
					ParseNumber!<float>(split.GetNext()),
					ParseNumber!<float>(split.GetNext())
				));
			}
			else if (line.StartsWith("usemtl ")) {
				StringView name = line[7...];

				Material material;
				if (!obj.materials.TryGetValueAlt(name, out material)) Error!();

				part = new [Friend].(material);
				obj.parts.Add(part);
			}
			else if (line.StartsWith("f ")) {
				StringSplitEnumerator split = line[2...].Split(' ', .RemoveEmptyEntries);
				uint32[3] indices = .();

				for (int i < 3) {
					StringView string = split.GetNext().Value..Trim();

					int slashI = string.IndexOf('/');
					if (slashI != -1) string = string[...(slashI - 1)];

					indices[i] = ParseNumber!<uint32>(string);
				}

				if (part == null) {
					Material material = .();
					//material.baseColor = .(0.9f, 0.1f, 0.1f, 0);

					obj.materials[new .("__default__")] = material;

					part = new [Friend].(material);
					obj.parts.Add(part);
				}

				part.[Friend]triangles.Add(.(
					indices[0],
					indices[1],
					indices[2]
				));
			}
		}

		return obj;
	}

	private static Result<void> ParseMaterials(OBJ obj, StringView path) {
		StreamReader reader = scope .();
		if (reader.Open(path) case .Err) return .Err;

		String name = scope .();
		Vec3f albedo = .ZERO;

		mixin Add() {
			if (!name.IsEmpty) {
				obj.materials[new .(name)] = .();
			}
		}

		for (StringView line in reader.Lines) {
			if (line.StartsWith('#')) continue;

			if (line.StartsWith("newmtl ")) {
				Add!();

				name.Set(line[7...]);
			}
			else if (line.StartsWith("Kd ")) {
				StringSplitEnumerator split = line[3...].Split(' ', .RemoveEmptyEntries);

				for (int i < 3) {
					switch (float.Parse(split.GetNext().Value..Trim())) {
					case .Ok(let val):	albedo[i] = val;
					case .Err:			return .Err;
					}
				}
			}
		}

		Add!();

		return .Ok;
	}
}*/