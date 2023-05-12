using System;

using Bulkan;
using static Bulkan.VulkanNative;

namespace Terra.Gpu;

extension Gpu {
	private VkQueryPool queryPool;

	private Result<void> InitQueryPool() {
		VkQueryPoolCreateInfo info = .() {
			queryType = .VK_QUERY_TYPE_TIMESTAMP,
			queryCount = 2
		};

		VkResult result = vkCreateQueryPool(device, &info, null, &queryPool);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create query pool");

		return .Ok;
	}

	private void DestroyQueryPool() {
		vkDestroyQueryPool(device, queryPool, null);
	}

	public void BeginQuery(VkCommandBuffer commandBuffer) {
		vkCmdWriteTimestamp(commandBuffer, .VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, queryPool, 0);
	}

	public void EndQuery(VkCommandBuffer commandBuffer) {
		vkCmdWriteTimestamp(commandBuffer, .VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, queryPool, 1);
	}

	public void PrepareQuery() {
		vkResetQueryPool(device, queryPool, 0, 2);
	}

	public Result<TimeSpan> GetQuery() {
		uint64[2] timestamps = ?;

		VkResult result = vkGetQueryPoolResults(device, queryPool, 0, 2, sizeof(decltype(timestamps)), &timestamps[0], sizeof(uint64), .VK_QUERY_RESULT_64_BIT);
		if (result != .VK_SUCCESS) return Log.ErrorResult<TimeSpan>("Failed to get query");

		return TimeSpan((.) ((timestamps[1] - timestamps[0]) * (double) properties.limits.timestampPeriod / 100.0));
	}
}