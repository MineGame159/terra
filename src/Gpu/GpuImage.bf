using System;

using Bulkan;
using Bulkan.Utilities;
using static Bulkan.VulkanNative;
using static Bulkan.Utilities.VulkanMemoryAllocator;

namespace Terra.Gpu;

enum GpuImageFormat {
	case RGBA8u, RGBA32f;

	public VkFormat Vk { get {
		switch (this) {
		case .RGBA8u:	return .VK_FORMAT_R8G8B8A8_UNORM;
		case .RGBA32f:	return .VK_FORMAT_R32G32B32A32_SFLOAT;
		}
	} }

	public int Size { get {
		switch (this) {
		case .RGBA8u:	return 4;
		case .RGBA32f:	return 16;
		}
	} }
}

class GpuImage : GpuObject {
	public GpuImageFormat format;
	public int width, height;

	private VkImage handle;
	private VmaAllocation allocation;

	public VkImageView view;

	private this(Gpu gpu, GpuImageFormat format, int width, int height, VkImage handle, VmaAllocation allocation, VkImageView view) : base(gpu) {
		this.format = format;
		this.width = width;
		this.height = height;

		this.handle = handle;
		this.allocation = allocation;
		this.view = view;
	}

	public ~this() {
		vkDestroyImageView(gpu.device, view, null);
		vmaDestroyImage(gpu.allocator, handle, allocation);
	}

	public Result<GpuData> Map() {
		void* data = ?;
		VkResult result = vmaMapMemory(gpu.allocator, allocation, &data);

		if (result != .VK_SUCCESS) return .Err;
		return GpuData(gpu, allocation, data);
	}

	public static implicit operator VkImage(Self image) => image.handle;
}

struct GpuSampledImage : this(GpuImage image, Sampler sampler) {}

class GpuSampledImageArray : GpuObject {
	public GpuSampledImage[] images;

	[AllowAppend]
	public this(Gpu gpu, GpuSampledImage[] images) : base(gpu) {
		GpuSampledImage[] _images = append .[images.Count];
		images.CopyTo(_images);

		this.images = _images;
	}
}