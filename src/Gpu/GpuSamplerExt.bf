using System;
using System.Collections;

using Bulkan;
using static Bulkan.VulkanNative;

namespace Terra.Gpu;

enum TextureFilter {
	case Nearest, Linear;

	public VkFilter Vk { get {
		switch (this) {
		case .Nearest:	return .VK_FILTER_NEAREST;
		case .Linear:	return .VK_FILTER_LINEAR;
		}
	} }
}

struct Sampler {
	public TextureFilter min, mag;

	private VkSampler handle;

	private this(TextureFilter min, TextureFilter mag, VkSampler handle) {
		this.min = min;
		this.mag = mag;
		this.handle = handle;
	}

	public static implicit operator VkSampler(Self sampler) => sampler.handle;
}

extension Gpu {
	private List<Sampler> samplers = new .();

	private void DestroySamplers() {
		for (let sampler in samplers) {
			vkDestroySampler(device, sampler, null);
		}

		delete samplers;
	}

	public Result<Sampler> GetSampler(TextureFilter min, TextureFilter mag) {
		for (let sampler in samplers) {
			if (sampler.min == min && sampler.mag == mag) {
				return sampler;
			}
		}

		VkSamplerCreateInfo info = .() {
			minFilter = min.Vk,
			magFilter = mag.Vk
		};

		VkSampler handle = ?;

		VkResult result = vkCreateSampler(device, &info, null, &handle);
		if (result != .VK_SUCCESS) return Log.ErrorResult<Sampler>("Failed to create sampler");

		Sampler sampler = [Friend].(min, mag, handle);
		samplers.Add(sampler);

		return sampler;
	}
}