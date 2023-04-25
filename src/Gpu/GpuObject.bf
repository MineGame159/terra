using System;

using Bulkan.Utilities;
using static Bulkan.Utilities.VulkanMemoryAllocator;

namespace Nova.Gpu;

abstract class GpuObject {
	protected Gpu gpu;

	public this(Gpu gpu) {
		this.gpu = gpu;
	}
}

struct GpuData : IDisposable {
	private Gpu gpu;
	private VmaAllocation allocation;
	private void* data;

	public this(Gpu gpu, VmaAllocation allocation, void* data) {
		this.gpu = gpu;
		this.allocation = allocation;
		this.data = data;
	}

	public void Dispose() {
		vmaUnmapMemory(gpu.allocator, allocation);
	}

	public static implicit operator void*(Self data) => data.data;
}