using System;

using Bulkan;
using Bulkan.Utilities;
using static Bulkan.VulkanNative;
using static Bulkan.Utilities.VulkanMemoryAllocator;

namespace Terra.Gpu;

enum GpuBufferType {
	case Uniform, Storage;

	public VkBufferUsageFlags Vk { get {
		switch (this) {
		case .Uniform:	return .VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
		case .Storage:	return .VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
		}
	} }

	public ResourceType ResourceType { get {
		switch (this) {
		case .Uniform:	return .UniformBuffer;
		case .Storage:	return .StorageBuffer;
		}
	} }
}

class GpuBuffer : GpuObject {
	public GpuBufferType type;
	public uint64 size;

	private VkBuffer handle;
	private VmaAllocation allocation;

	public this(Gpu gpu, GpuBufferType type, uint64 size, VkBuffer handle, VmaAllocation allocation) : base(gpu) {
		this.type = type;
		this.size = size;

		this.handle = handle;
		this.allocation = allocation;
	}

	public ~this() {
		vmaDestroyBuffer(gpu.allocator, handle, allocation);
	}

	public Result<GpuData> Map() {
		if (size == 0) return .Err;

		void* data = ?;
		VkResult result = vmaMapMemory(gpu.allocator, allocation, &data);

		if (result != .VK_SUCCESS) return .Err;
		return GpuData(gpu, allocation, data);
	}

	public static implicit operator VkBuffer(Self buffer) => buffer.handle;
}