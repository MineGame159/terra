using System;

using Bulkan;
using static Bulkan.VulkanNative;

namespace Terra.Gpu;

extension Gpu {
	private VkCommandPool commandPool;

	private Result<void> InitCommandPool() {
		VkCommandPoolCreateInfo info = .() {
			flags = .VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
			queueFamilyIndex = FindQueueFamilies(physicalDevice).computeFamily.Value
		};

		VkResult result = vkCreateCommandPool(device, &info, null, &commandPool);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create command pool");

		return .Ok;
	}

	private void DestroyCommandPool() {
		vkDestroyCommandPool(device, commandPool, null);
	}

	public Result<VkCommandBuffer> CreateCommandBuffer() {
		VkCommandBufferAllocateInfo info = .() {
			commandPool = commandPool,
			commandBufferCount = 1
		};

		VkCommandBuffer commandBuffer = ?;
		VkResult result = vkAllocateCommandBuffers(device, &info, &commandBuffer);
		if (result != .VK_SUCCESS) return Log.ErrorResult<VkCommandBuffer>("Failed to create command buffer");
		
		return commandBuffer;
	}
}