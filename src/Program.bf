using System;
using System.IO;
using System.Collections;

using Nova.Gpu;
using Nova.Scene;
using Nova.Math;
using Nova.Profiler;

namespace Nova;

static class Program {
	private const uint8[?] SHADER_DATA = Compiler.ReadBinary("shader/shader.spv");

	const int SIZE = 8;

	[Profile(false)]
	public static void Main() {
		// Initialize GPU
		Gpu gpu = scope .();
		if (gpu.Init() == .Err) return;

		// Scene
		StringView path = "scenes/models/forklift.gltf";

		GpuSceneBuilder scene = scope .(gpu);

		if (SceneLoaders.Load(scene, path) == .Err) {
			Log.Error("Failed to load scene");
			return;
		}

		// Input
		Zone zone = .(Locations.Create("Input"));

		InputData input = scope .();

		/*input.width = 960;
		input.height = 540;
		input.samples = 16;*/

		PrintStats(scene);

		while (input.NeedsInput) {
			Console.Clear();
			PrintStats(scene);

			input.GetInput();
		}

		Console.WriteLine();

		zone.Dispose();

		// Create resources
		zone = .(Locations.Create("CreateResources"));

		let globalDataBuffer = scene.CreateSceneDataBuffer(gpu, input.width, input.height);
		let (sphereBvhBuffer, spherePrimitivesBuffer) = scene.CreateSphereBuffers(gpu).Value;
		let (triangleBvhBuffer, trianglePrimitivesBuffer) = scene.CreateTriangleBuffers(gpu).Value;
		let (meshInstanceBvhBuffer, meshInstancePrimitivesBuffer) = scene.CreateMeshInstanceBuffers(gpu).Value;

		GpuBuffer materialsBuffer = scene.CreateMaterialsBuffer(gpu).Value;

		GpuSampledImageArray textures = scene.GetSampledImageArray!(gpu);

		GpuImage image1 = gpu.CreateImage(.RGBA32f, input.width, input.height, false);
		GpuImage image2 = gpu.CreateImage(.RGBA32f, input.width, input.height, false);

		// Create program and instance
		GpuProgram program = gpu.CreateProgram(SHADER_DATA, sizeof(uint32), .UniformBuffer, .StorageBuffer, .StorageBuffer, .StorageBuffer, .StorageBuffer, .StorageBuffer, .StorageBuffer, .StorageBuffer, .SampledImageArray(scene.TextureCount), .Image, .Image);

		GpuProgramInstance instance1 = program.CreateInstance(globalDataBuffer, sphereBvhBuffer, spherePrimitivesBuffer, triangleBvhBuffer, trianglePrimitivesBuffer, meshInstanceBvhBuffer, meshInstancePrimitivesBuffer, materialsBuffer, textures, image1, image2);
		GpuProgramInstance instance2 = program.CreateInstance(globalDataBuffer, sphereBvhBuffer, spherePrimitivesBuffer, triangleBvhBuffer, trianglePrimitivesBuffer, meshInstanceBvhBuffer, meshInstancePrimitivesBuffer, materialsBuffer, textures, image2, image1);

		zone.Dispose();

		// Execute program
		zone = .(Locations.Create("Render"));

		Console.WriteLine("Rendering");

		int width = input.width / SIZE;
		int height = input.height / SIZE;

		if (input.width - width > 0) width += SIZE;
		if (input.height - height > 0) height += SIZE;

		uint32 sample = 0;
		GpuImage outputImage = null;

		int lastProgress = 0;

		void PrintProgress(int progress) {
			Console.MyCursorLeft = 0;
			Console.Write('[');

			for (int i < 50) {
				Console.Write(i <= progress ? '*' : ' ');
			}

			Console.Write(']');
		}

		PrintProgress(0);

		TimeSpan totalDuration = 0;

		for (int i < input.samples) {
			GpuProgramInstance instance;

			if (i % 2 == 0) {
				instance = instance1;
				outputImage = image2;
			}
			else {
				instance = instance2;
				outputImage = image1;
			}

			totalDuration += instance.Execute(sample, width, height);

			sample++;

			int progress = (.) ((double) sample / input.samples * 50);
			if (progress != lastProgress) PrintProgress(progress);
			lastProgress = progress;
		}

		zone.Dispose();

		// Print render stats
		Console.WriteLine();
		Console.WriteLine();

		Console.WriteLine("Total duration:          {}", FormatDuration(totalDuration, .. scope .()));
		Console.WriteLine("Average sample duration: {}", FormatDuration(totalDuration / .(input.samples), .. scope .()));

		Console.WriteLine();

		// Save image
		zone = .(Locations.Create("SaveImage"));

		using (Timer("Saved image")) {
			using (let data = outputImage.Map().Value) {
				Image outImage = scope .(input.width, input.height);
	
				for (int x < input.width) {
					for (int y < input.height) {
						float* pixel = &((float*) data)[(x + (input.height - y - 1) * input.width) * 4];
						Vec3f color = .(pixel[0], pixel[1], pixel[2]);

						color = color.Max(.ZERO);
						color = ToneMapping.ToneMap(color, .ReinhardJodie);

						const float gamma = 2.2f;
						color = color.Pow(1 / gamma);
	
						outImage.Get(x, y) = .(
							(.) (Math.Clamp(color.x, 0, 0.999) * 256),
							(.) (Math.Clamp(color.y, 0, 0.999) * 256),
							(.) (Math.Clamp(color.z, 0, 0.999) * 256)
						);
					}
				}
	
				outImage.Write("image.png");
			}
		}

		Console.WriteLine("Saved to image.png");

		zone.Dispose();

		// Finished
		__zone.Dispose();

		Console.Read();

		// Export profile
		Profile profile = .Parse();
		ProfileTxtExporter.Export(profile, "profile.txt");
		delete profile;
	}

	private static void PrintStats(ISceneBuilder scene) {
		SceneStats stats = scene.Stats;
		
		Console.WriteLine("Spheres:   {:#,0} ({})", stats.sphereCount, FormatBytes(stats.sphereBytes, .. scope .()));
		Console.WriteLine("Triangles: {:#,0} ({})", stats.triangleCount, FormatBytes(stats.triangleBytes, .. scope .()));
		Console.WriteLine("Meshes:    {:#,0} ({})", stats.meshCount, FormatBytes(stats.meshBytes, .. scope .()));

		Console.WriteLine("Materials: {:#,0} ({})", stats.materialCount, FormatBytes(stats.materialBytes, .. scope .()));
		Console.WriteLine("Textures:  {:#,0} ({})", stats.textureCount, FormatBytes(stats.textureBytes, .. scope .()));

		Console.WriteLine();
	}

	private static void FormatBytes(uint64 bytes, String str) {
		if (bytes / 1024.0 < 1) {
			str.AppendF("{:0.##} B", bytes);
			return;
		}

		double kb = bytes / 1024.0;

		if (kb / 1024 < 1) {
			str.AppendF("{:0.##} KB", kb);
		}
		else {
			str.AppendF("{:0.##} MB", kb / 1024);
		}
	}

	private static void FormatDuration(TimeSpan duration, String str) {
		if (duration.TotalSeconds < 1) str.AppendF("{:0.000} milliseconds", duration.TotalMilliseconds);
		else if (duration.TotalMinutes < 1) str.AppendF("{:0.000} seconds", duration.TotalSeconds);
		else str.AppendF("{:0.000} minutes", duration.TotalMinutes);
	}
}

class InputData {
	public int width;
	public int height;

	public int samples;

	public bool NeedsInput => width == 0 || height == 0 || samples == 0;

	public void GetInput() {
		if (width == 0) {
			Console.Write("Image Width: ");
			StringView str = Console.MyReadLine(.. scope .());

			if (str.Equals("qhd", true)) {
				width = 960;
				height = 540;
			}
			else if (str.Equals("hd", true)) {
				width = 1280;
				height = 720;
			}
			else if (str.Equals("fullhd", true) || str.Equals("full_hd", true)) {
				width = 1920;
				height = 1080;
			}
			else if (int.Parse(str) case .Ok(let val)) {
				width = val;
			}
		}
		else if (height == 0) {
			Console.WriteLine("Image Width: {}", width);

			Console.Write("Image Height: ");
			StringView str = Console.MyReadLine(.. scope .());

			if (str.IsEmpty) {
				const double aspectRatio = 16.0 / 9.0;
				height = (.) (width / aspectRatio);
			}
			else {
				if (int.Parse(str) case .Ok(let val)) {
					height = val;
				}
			}
		}
		else if (samples == 0) {
			Console.WriteLine("Image Width: {}", width);
			Console.WriteLine("Image Height: {}", height);

			Console.Write("Samples: ");
			StringView str = Console.MyReadLine(.. scope .());

			if (int.Parse(str) case .Ok(let val)) {
				samples = val;
			}
		}
	}

	public void Print() {
		if (width != 0) Console.WriteLine("Image Width: {}", width);
		if (height != 0) Console.WriteLine("Image Height: {}", height);
		if (samples != 0) Console.WriteLine("Samples: {}", samples);

		if (width != 0 || height != 0 || samples != 0) Console.WriteLine();
	}
}