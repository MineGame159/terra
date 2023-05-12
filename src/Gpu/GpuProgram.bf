using System;

using Bulkan;
using static Bulkan.VulkanNative;

namespace Terra.Gpu;

class GpuProgram : GpuObject {
	private VkShaderModule shader;
	private VkPipelineLayout pipelineLayout;
	private VkPipeline pipeline;

	private this(Gpu gpu, VkShaderModule shader, VkPipelineLayout pipelineLayout, VkPipeline pipeline) : base(gpu) {
		this.shader = shader;
		this.pipelineLayout = pipelineLayout;
		this.pipeline = pipeline;
	}

	public ~this() {
		vkDestroyPipeline(gpu.device, pipeline, null);
		vkDestroyPipelineLayout(gpu.device, pipelineLayout, null);
		vkDestroyShaderModule(gpu.device, shader, null);
	}

	public Result<GpuProgramInstance> CreateInstance(params GpuObject[] resources) {
		// Set
		VkDescriptorSet set = gpu.CreateDescriptorSet(resources).GetOrPropagate!();

		// Command buffer
		VkCommandBuffer commandBuffer = gpu.CreateCommandBuffer().GetOrPropagate!();

		// Create
		GpuProgramInstance instance = new [Friend].(gpu, this, set, commandBuffer, resources);
		gpu.[Friend]objects.Add(instance);

		return instance;
	}
}