using System;
using System.IO;
using System.Collections;

using Terra.Math;
using Terra.Profiler;

namespace Terra.Scene.Loaders;

class ObjMeshLoader : IMeshLoader {
	private append String path = .();
	private uint32 materialId;

	private List<Vec3f> positions = new .(1024) ~ delete _;
	private List<Vec2f> uvs = new .(1024) ~ delete _;
	private List<Vec3f> normals = new .(1024) ~ delete _;

	private List<Vec<int32, 3>[3]> triangles = new .(1024) ~ delete _;

	public this(StringView path, uint32 materialId) {
		this.path.Set(path);
		this.materialId = materialId;
	}

	public int TriangleCount => triangles.Count * 3;
	
	[Profile]
	public Result<void> Parse() {
		StreamReader reader = scope .();
		if (reader.Open(path) case .Err) return .Err;

		String line = scope .(64);

		for (LineEnumerator(reader, line)) {
			StringSplitEnumerator split = line.Split(' ', .RemoveEmptyEntries);
			StringView type = split.GetNext().GetOrPropagate!();
			
			switch (type) {
			case "v":	positions.Add(ParseVec3!(split));
			case "vt":	uvs.Add(ParseVec2!(split));
			case "vn":	normals.Add(ParseVec3!(split));

			case "f":
				let i0 = ParseIndex!(split);
				let i1 = ParseIndex!(split);
				let i2 = ParseIndex!(split);

				triangles.Add(.(i0, i1, i2));

				if (split.HasMore) {
					let i3 = ParseIndex!(split);
					triangles.Add(.(i2, i3, i0));
				}
			}
		}

		return .Ok;
	}
	
	[Profile]
	public Result<void> Load(IMeshBuilder mesh) {
		if (normals.IsEmpty) normals.Add(.(0, 1, 0));
		if (uvs.IsEmpty) uvs.Add(.ZERO);

		for (let triangle in triangles) {
			mesh.AddTriangle(
				.(
				positions[triangle[0][0]],
				positions[triangle[1][0]],
				positions[triangle[2][0]]
				),
				.(
				normals[triangle[0][2]],
				normals[triangle[1][2]],
				normals[triangle[2][2]]
				),
				.(
				uvs[triangle[0][1]],
				uvs[triangle[1][1]],
				uvs[triangle[2][1]]
				),
				materialId
			);
		}
		
		return .Ok;
	}

	private mixin ParseFloat(StringSplitEnumerator split) {
		float.Parse(split.GetNext().GetOrPropagate!()).GetOrPropagate!()
	}

	private mixin ParseVec2(StringSplitEnumerator split) {
		Vec2f(ParseFloat!(split), ParseFloat!(split))
	}

	private mixin ParseVec3(StringSplitEnumerator split) {
		Vec3f(ParseFloat!(split), ParseFloat!(split), ParseFloat!(split))
	}

	private mixin ParseIndex(StringSplitEnumerator split) {
		StringView str = split.GetNext().GetOrPropagate!();
		int32[3] values = .();

		StringSplitEnumerator split2 = str.Split('/');
		int i = 0;

		for (let str2 in split2) {
			if (str2.IsEmpty) {
				i++;
				continue;
			}

			switch (int32.Parse(str2)) {
			case .Ok(let val):	values[i++] = val - 1;
			case .Err:			return .Err;
			}
		}

		Vec<int32, 3>(values)
	}
}