using System;

using Nova.Scene.Loaders;

namespace Nova.Scene;

static class SceneLoaders {
	public static Result<void> Load(ISceneBuilder scene, StringView path) {
		if (path.EndsWith(".gltf") || path.EndsWith(".glb"))
			return scope GltfSceneLoader(path).Load(scene);
		else
			return .Err;
	}
}