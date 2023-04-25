using System;
using System.Collections;

using Bulkan;
using static Bulkan.VulkanNative;

namespace Nova.Gpu;

enum ResourceType {
	case UniformBuffer, StorageBuffer, Image;
	case SampledImageArray(int count);

	public VkDescriptorType Vk { get {
		switch (this) {
		case .UniformBuffer:		return .VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
		case .StorageBuffer:		return .VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
		case .Image:				return .VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
		case .SampledImageArray:	return .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
		}
	} }

	public int Count { get {
		switch (this) {
		case .SampledImageArray(let count):	return count;
		default:							return 1;
		}
	} }
}

extension Gpu {
	private VkDescriptorPool descriptorPool;
	private List<DescriptorLayoutHolder> layouts = new .();

	private Result<void> InitDescriptorPool() {
		VkDescriptorPoolSize[?] sizes = .(
			.() {
				type = .VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
				descriptorCount = 16
			},
			.() {
				type = .VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
				descriptorCount = 16
			},
			.() {
				type = .VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
				descriptorCount = 16
			},
			.() {
				type = .VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
				descriptorCount = 64
			}
		);

		VkDescriptorPoolCreateInfo info = .() {
			maxSets = 8,
			poolSizeCount = sizes.Count,
			pPoolSizes = &sizes
		};

		VkResult result = vkCreateDescriptorPool(device, &info, null, &descriptorPool);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create descriptor pool");

		return .Ok;
	}

	private void DestroyDescriptorPool() {
		DeleteContainerAndItems!(layouts);
		vkDestroyDescriptorPool(device, descriptorPool, null);
	}

	public Result<VkDescriptorSetLayout> GetDescriptorLayout(ResourceType[] types) {
		for (DescriptorLayoutHolder holder in layouts) {
			if (holder.Equals(types)) return holder.layout;
		}

		VkDescriptorSetLayoutBinding[] layoutBindings = scope .[types.Count];

		for (int i < types.Count) {
			layoutBindings[i] = .() {
				binding = (.) i,
				descriptorCount = (.) types[i].Count,
				descriptorType = types[i].Vk,
				stageFlags = .VK_SHADER_STAGE_COMPUTE_BIT
			};
		}

		VkDescriptorSetLayoutCreateInfo layoutInfo = .() {
			bindingCount = (.) layoutBindings.Count,
			pBindings = &layoutBindings[0]
		};

		VkDescriptorSetLayout layout = ?;
		VkResult result = vkCreateDescriptorSetLayout(device, &layoutInfo, null, &layout);
		if (result != .VK_SUCCESS) return Log.ErrorResult<VkDescriptorSetLayout>("Failed to create descriptor set layout");

		layouts.Add(new .(this, layout, types));

		return layout;
	}

	public Result<VkDescriptorSet> CreateDescriptorSet(GpuObject[] resources) {
		// Layout
		ResourceType[] types = scope .[resources.Count];

		for (int i < resources.Count) {
			types[i] = GetResourceType(resources[i]).GetOrPropagate!();
		}

		VkDescriptorSetLayout layout = GetDescriptorLayout(types).GetOrPropagate!();

		// Handle
		VkDescriptorSetAllocateInfo setInfo = .() {
			descriptorPool = descriptorPool,
			descriptorSetCount = 1,
			pSetLayouts = &layout
		};

		VkDescriptorSet handle = ?;
		VkResult result = vkAllocateDescriptorSets(device, &setInfo, &handle);

		if (result != .VK_SUCCESS) {
			vkDestroyDescriptorSetLayout(device, layout, null);
			return .Err;
		}

		List<VkWriteDescriptorSet> writes = scope .();

		for (int i < resources.Count) {
			GpuObject resource = resources[i];

			VkDescriptorBufferInfo* bufferInfo = null;
			VkDescriptorImageInfo* imageInfo = null;

			mixin AddSingle(GpuObject resource) {
				if (resource is GpuBuffer) {
					GpuBuffer buffer = (.) resource;
	
					bufferInfo = scope:: .() {
						buffer = buffer,
						offset = 0,
						range = VK_WHOLE_SIZE
					};
				}
				else if (resource is GpuImage) {
					GpuImage image = (.) resource;
	
					imageInfo = scope:: .() {
						sampler = .Null,
						imageView = image.view,
						imageLayout = .VK_IMAGE_LAYOUT_GENERAL
					};
				}
				else {
					Runtime.NotImplemented();
				}
	
				writes.Add(.() {
					dstSet = handle,
					dstBinding = (.) i,
					descriptorCount = 1,
					descriptorType = GetResourceType(resource).Value.Vk,
					pBufferInfo = bufferInfo,
					pImageInfo = imageInfo
				});
			}

			if (resource is GpuSampledImageArray) {
				uint32 j = 0;

				for (let sampledImage in ((GpuSampledImageArray) resource).images) {
					imageInfo = scope:: .() {
						sampler = sampledImage.sampler,
						imageView = sampledImage.image.view,
						imageLayout = .VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
					};

					writes.Add(.() {
						dstSet = handle,
						dstBinding = (.) i,
						dstArrayElement = j++,
						descriptorCount = 1,
						descriptorType = GetResourceType(resource).Value.Vk,
						pImageInfo = imageInfo
					});
				}
			}
			else {
				AddSingle!(resource);
			}
		}

		vkUpdateDescriptorSets(device, (.) writes.Count, &writes[0], 0, null);

		// Return
		return handle;
	}

	
	private Result<ResourceType> GetResourceType(GpuObject resource) {
		if (resource is GpuBuffer) return ((GpuBuffer) resource).type.ResourceType;
		else if (resource is GpuImage) return ResourceType.Image;
		else if (resource is GpuSampledImageArray) return ResourceType.SampledImageArray(((GpuSampledImageArray) resource).images.Count);

		Log.Error("Invalid resource");
		return .Err;
	}

	private class DescriptorLayoutHolder {
		private Gpu gpu;

		public ResourceType[] types ~ delete _;
		public VkDescriptorSetLayout layout ~ vkDestroyDescriptorSetLayout(gpu.device, _, null);

		public this(Gpu gpu, VkDescriptorSetLayout layout, ResourceType[] types) {
			this.gpu = gpu;
			this.types = new .[types.Count];
			this.layout = layout;

			types.CopyTo(this.types);
		}

		public bool Equals(ResourceType[] types) {
			if (this.types.Count != types.Count) return false;

			for (int i < types.Count) {
				if (this.types[i] != types[i]) return false;
			}

			return true;
		}
	}
}