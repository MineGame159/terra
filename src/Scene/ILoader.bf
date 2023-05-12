using System;

namespace Terra.Scene;

interface ISceneLoader {
	Result<void> Load(ISceneBuilder scene);
}

interface IMeshLoader {
	Result<void> Load(IMeshBuilder mesh);
}