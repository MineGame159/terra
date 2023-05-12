using System;

using Bulkan;
using Bulkan.Utilities;
using static Bulkan.VulkanNative;

using Terra.Profiler;

namespace Terra.Gpu;

class GpuProgramInstance : GpuObject {
	private GpuProgram program;
	private VkDescriptorSet set;
	private VkCommandBuffer commandBuffer;
	private GpuObject[] resources ~ delete _;

	private this(Gpu gpu, GpuProgram program, VkDescriptorSet set, VkCommandBuffer commandBuffer, GpuObject[] resources) : base(gpu) {
		this.set = set;
		this.program = program;
		this.commandBuffer = commandBuffer;
		this.resources = new .[resources.Count];

		resources.CopyTo(this.resources);
	}

	[Profile]
	public Result<TimeSpan> Execute<T>(T pushConstant, int xCount, int yCount) where T : struct {
		// Record
		VkCommandBufferBeginInfo beginInfo = .();

		VkResult result = vkBeginCommandBuffer(commandBuffer, &beginInfo);
		if (result != .VK_SUCCESS) return Log.ErrorResult<TimeSpan>("Failed to begin command buffer");

		for (GpuObject resource in resources) {
			if (resource is GpuImage) TransitionImage(commandBuffer, (GpuImage) resource, .THSVS_ACCESS_NONE, .THSVS_ACCESS_COMPUTE_SHADER_WRITE);
			else if (resource is GpuSampledImageArray) {
				for (let sampledImage in ((GpuSampledImageArray) resource).images) {
					TransitionImage(commandBuffer, sampledImage.image, .THSVS_ACCESS_NONE, .THSVS_ACCESS_COMPUTE_SHADER_READ_SAMPLED_IMAGE_OR_UNIFORM_TEXEL_BUFFER);
				}
			}
		}

		vkCmdBindPipeline(commandBuffer, .VK_PIPELINE_BIND_POINT_COMPUTE, program.[Friend]pipeline);
		vkCmdBindDescriptorSets(commandBuffer, .VK_PIPELINE_BIND_POINT_COMPUTE, program.[Friend]pipelineLayout, 0, 1, &set, 0, null);

		if (sizeof(T) > 0) {
#unwarn
			vkCmdPushConstants(commandBuffer, program.[Friend]pipelineLayout, .VK_SHADER_STAGE_COMPUTE_BIT, 0, (.) sizeof(T), &pushConstant);
		}
		
		gpu.BeginQuery(commandBuffer);
		vkCmdDispatch(commandBuffer, (.) xCount, (.) yCount, 1);
		gpu.EndQuery(commandBuffer);

		result = vkEndCommandBuffer(commandBuffer);
		if (result != .VK_SUCCESS) return Log.ErrorResult<TimeSpan>("Failed to end command buffer");

		// Execute
		gpu.PrepareQuery();
		vkResetFences(gpu.device, 1, &gpu.fence);
		
		VkSubmitInfo submitInfo = .() {
			commandBufferCount = 1,
			pCommandBuffers = &commandBuffer
		};

		result = vkQueueSubmit(gpu.computeQueue, 1, &submitInfo, gpu.fence);
		if (result != .VK_SUCCESS) return Log.ErrorResult<TimeSpan>("Failed to submit command buffer");

		result = vkWaitForFences(gpu.device, 1, &gpu.fence, .True, uint64.MaxValue);
		if (result != .VK_SUCCESS) return Log.ErrorResult<TimeSpan>("Failed to wait for fence");

		return gpu.GetQuery();
	}

	public Result<TimeSpan> Execute(int xCount, int yCount) => Execute<void>(default, xCount, yCount);

	private static void TransitionImage(VkCommandBuffer commandBuffer, VkImage image, ThsvsAccessType prev, ThsvsAccessType next) {
		ThsvsGlobalBarrier* globalBarrier = null;
		ThsvsBufferBarrier* bufferBarrier = null;

#unwarn
		ThsvsImageBarrier imageBarrier = .() {
			prevAccessCount = 1,
			pPrevAccesses = &prev,
			nextAccessCount = 1,
			pNextAccesses = &next,
			prevLayout = .THSVS_IMAGE_LAYOUT_OPTIMAL,
			nextLayout = .THSVS_IMAGE_LAYOUT_OPTIMAL,
			srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
			image = image,
			subresourceRange = .() {
				aspectMask = .VK_IMAGE_ASPECT_COLOR_BIT,
				baseMipLevel = 0,
				levelCount = 1,
				layerCount = 1
			}
		};

		thsvsCmdPipelineBarrier(commandBuffer, globalBarrier, 0, bufferBarrier, 1, &imageBarrier);
	}
}