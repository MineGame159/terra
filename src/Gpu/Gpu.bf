using System;
using System.IO;
using System.Collections;

using Bulkan;
using Bulkan.Utilities;
using static Bulkan.VulkanNative;
using static Bulkan.Utilities.VulkanMemoryAllocator;

namespace Nova.Gpu;

class Gpu {
	private const bool VALIDATION =
#if DEBUG
		true;
#else
		false;
#endif

	public VkInstance instance;
	public VkDebugUtilsMessengerEXT messenger;
	public VkPhysicalDevice physicalDevice;

	public VkDevice device;
	public VkQueue computeQueue;

	public VkPhysicalDeviceProperties properties;
	public VmaAllocator allocator;

	public VkFence fence;

	private List<GpuObject> objects = new .();

	public ~this() {
		vkDeviceWaitIdle(device);

		for (int i = objects.Count - 1; i >= 0; i--) {
			delete objects[i];
		}
		delete objects;

		vkDestroyFence(device, fence, null);

		DestroySamplers();
		DestroyQueryPool();
		DestroyCommandPool();
		DestroyDescriptorPool();

		vmaDestroyAllocator(allocator);

		vkDestroyDevice(device, null);

		vkDestroyDebugUtilsMessengerEXT(instance, messenger, null);
		vkDestroyInstance(instance, null);
	}

	public Result<void> Init() {
		// Initialize Vulkan library
		VulkanNative.Initialize();
		VulkanNative.LoadPreInstanceFunctions();

		// Create Vulkan objects
		CreateInstance().GetOrPropagate!();
		SetupDebugCallback().GetOrPropagate!();
		FindPhysicalDevice().GetOrPropagate!();
		CreateDevice().GetOrPropagate!();

		// Query GPU properties
		vkGetPhysicalDeviceProperties(physicalDevice, &properties);

		// Create VMA allocator
		VmaAllocatorCreateInfo allocatorInfo = .() {
			physicalDevice = physicalDevice,
			device = device,
			instance = instance,
			vulkanApiVersion = Version(1, 2, 0)
		};

		VkResult result = vmaCreateAllocator(&allocatorInfo, &allocator);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create memory allocator");

		// Initialize extensions
		InitDescriptorPool().GetOrPropagate!();
		InitCommandPool().GetOrPropagate!();
		InitQueryPool().GetOrPropagate!();

		// Create fence
		VkFenceCreateInfo fenceInfo = .();

		result = vkCreateFence(device, &fenceInfo, null, &fence);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create fence");

		// Return
		Log.Info("Initialized ray tracer");
		return .Ok;
	}

	// Resources

	public Result<GpuBuffer> CreateBuffer(GpuBufferType type, uint64 size) {
		VkBufferCreateInfo bufferInfo = .() {
			usage = type.Vk | .VK_BUFFER_USAGE_TRANSFER_DST_BIT,
			size = size > 0 ? size : 1
		};

		VmaAllocationCreateInfo allocationInfo = .() {
			usage = .VMA_MEMORY_USAGE_AUTO,
			flags = .VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT
		};

		VkBuffer handle = ?;
		VmaAllocation allocation = ?;

		VkResult result = vmaCreateBuffer(allocator, &bufferInfo, &allocationInfo, &handle, &allocation, null);
		if (result != .VK_SUCCESS) return .Err;

		GpuBuffer buffer = new [Friend].(this, type, size, handle, allocation);
		objects.Add(buffer);

		return buffer;
	}

	public Result<GpuImage> CreateImage(GpuImageFormat format, int width, int height, bool texture) {
		VkImageCreateInfo imageInfo = .() {
			imageType = .VK_IMAGE_TYPE_2D,
			format = format.Vk,
			extent = .() {
				width = (.) width,
				height = (.) height,
				depth = 1
			},
			mipLevels = 1,
			arrayLayers = 1,
			samples = .VK_SAMPLE_COUNT_1_BIT,
			tiling = .VK_IMAGE_TILING_LINEAR,
			usage = texture ? .VK_IMAGE_USAGE_SAMPLED_BIT : .VK_IMAGE_USAGE_STORAGE_BIT,
			initialLayout = .VK_IMAGE_LAYOUT_UNDEFINED
		};

		VmaAllocationCreateInfo allocationInfo = .() {
			usage = .VMA_MEMORY_USAGE_AUTO,
			flags = .VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT
		};

		VkImage handle = ?;
		VmaAllocation allocation = ?;

		VkResult result = vmaCreateImage(allocator, &imageInfo, &allocationInfo, &handle, &allocation, null);
		if (result != .VK_SUCCESS) return .Err;

		VkImageViewCreateInfo imageViewInfo = .() {
			image = handle,
			viewType = .VK_IMAGE_VIEW_TYPE_2D,
			format = format.Vk,
			components = .() {
				r = .VK_COMPONENT_SWIZZLE_IDENTITY,
				g = .VK_COMPONENT_SWIZZLE_IDENTITY,
				b = .VK_COMPONENT_SWIZZLE_IDENTITY,
				a = .VK_COMPONENT_SWIZZLE_IDENTITY
			},
			subresourceRange = .() {
				aspectMask = .VK_IMAGE_ASPECT_COLOR_BIT,
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1
			}
		};

		VkImageView view = ?;
		result = vkCreateImageView(device, &imageViewInfo, null, &view);

		if (result != .VK_SUCCESS) {
			vmaDestroyImage(allocator, handle, allocation);
			return .Err;
		}

		GpuImage image = new [Friend].(this, format, width, height, handle, allocation, view);
		objects.Add(image);

		return image;
	}

	public Result<GpuProgram> CreateProgram(Span<uint8> shaderData, uint64 pushConstantSize, params ResourceType[] resourceTypes) {
		// Descriptor set layout
		VkDescriptorSetLayout setLayout = GetDescriptorLayout(resourceTypes).GetOrPropagate!();

		// Shader
		VkShaderModuleCreateInfo shaderInfo = .() {
			codeSize = (.) shaderData.Length,
			pCode = (.) shaderData.Ptr
		};

		VkShaderModule shader = ?;
		VkResult result = vkCreateShaderModule(device, &shaderInfo, null, &shader);

		if (result != .VK_SUCCESS) {
			vkDestroyDescriptorSetLayout(device, setLayout, null);
			return .Err;
		}

		// Pipeline layout
		VkPushConstantRange pushConstantRange = .() {
			stageFlags = .VK_SHADER_STAGE_COMPUTE_BIT,
			offset = 0,
			size = (.) pushConstantSize
		};

		VkPipelineLayoutCreateInfo pipelineLayoutInfo = .() {
			pushConstantRangeCount = pushConstantSize > 0 ? 1 : 0,
			pPushConstantRanges = &pushConstantRange,
			setLayoutCount = 1,
			pSetLayouts = &setLayout
		};

		VkPipelineLayout pipelineLayout = ?;
		result = vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &pipelineLayout);

		if (result != .VK_SUCCESS) {
			vkDestroyShaderModule(device, shader, null);
			vkDestroyDescriptorSetLayout(device, setLayout, null);
			return .Err;
		}

		VkComputePipelineCreateInfo pipelineInfo = .() {
			layout = pipelineLayout,
			stage = .() {
				stage = .VK_SHADER_STAGE_COMPUTE_BIT,
				module = shader,
				pName = "main"
			}
		};

		// Pipeline
		VkPipeline pipeline = ?;
		result = vkCreateComputePipelines(device, .Null, 1, &pipelineInfo, null, &pipeline);

		if (result != .VK_SUCCESS) {
			vkDestroyPipelineLayout(device, pipelineLayout, null);
			vkDestroyShaderModule(device, shader, null);
			vkDestroyDescriptorSetLayout(device, setLayout, null);
			return .Err;
		}

		// Create
		GpuProgram program = new [Friend].(this, shader, pipelineLayout, pipeline);
		objects.Add(program);

		return program;
	}

	public Result<void> Upload(GpuBuffer buffer, void* data) {
		// Create staging buffer
		VkBufferCreateInfo bufferInfo = .() {
			usage = .VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
			size = buffer.size
		};

		VmaAllocationCreateInfo allocationInfo = .() {
			usage = .VMA_MEMORY_USAGE_AUTO,
			flags = .VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT
		};

		VkBuffer stagingBuffer = ?;
		VmaAllocation stagingAllocation = ?;

		VkResult result = vmaCreateBuffer(allocator, &bufferInfo, &allocationInfo, &stagingBuffer, &stagingAllocation, null);
		if (result != .VK_SUCCESS) return .Err;

		// Upload to staging buffer
		void* stagingBufferPtr = ?;

		result = vmaMapMemory(allocator, stagingAllocation, &stagingBufferPtr);
		if (result != .VK_SUCCESS) return .Err;

		Internal.MemCpy(stagingBufferPtr, data, (.) buffer.size);

		vmaUnmapMemory(allocator, stagingAllocation);

		// Create command buffer
		VkCommandBuffer commandBuffer = CreateCommandBuffer().GetOrPropagate!();

		// Record command buffer
		VkCommandBufferBeginInfo beginInfo = .();

		result = vkBeginCommandBuffer(commandBuffer, &beginInfo);
		if (result != .VK_SUCCESS) return .Err;

		VkBufferCopy copyInfo = .() {
			srcOffset = 0,
			dstOffset = 0,
			size = buffer.size
		};

		vkCmdCopyBuffer(commandBuffer, stagingBuffer, buffer, 1, &copyInfo);

		result = vkEndCommandBuffer(commandBuffer);
		if (result != .VK_SUCCESS) return .Err;

		// Execute
		vkResetFences(device, 1, &fence);

		VkSubmitInfo submitInfo = .() {
			commandBufferCount = 1,
			pCommandBuffers = &commandBuffer
		};

		result = vkQueueSubmit(computeQueue, 1, &submitInfo, fence);
		if (result != .VK_SUCCESS) return .Err;

		result = vkWaitForFences(device, 1, &fence, .True, uint64.MaxValue);
		if (result != .VK_SUCCESS) return .Err;

		// Destroy staging buffer
		vmaDestroyBuffer(allocator, stagingBuffer, stagingAllocation);

		return .Ok;
	}

	public Result<void> Upload(GpuImage image, Image img) {
		void* data = ?;

		VkResult result = vmaMapMemory(allocator, image.[Friend]allocation, &data);
		if (result != .VK_SUCCESS) return .Err;

		Internal.MemCpy(data, img.pixels, image.width * image.height * 4);

		vmaUnmapMemory(allocator, image.[Friend]allocation);

		return .Ok;
	}

	// Initialization

	private Result<void> CreateInstance() {
		VkApplicationInfo appInfo = .() {
			pApplicationName = "Nova Renderer",
			applicationVersion = Version(0, 1, 0),
			pEngineName = "Cacti",
			engineVersion = Version(0, 1, 0),
			apiVersion = Version(1, 2, 0)
		};

		List<char8*> extensions = scope .();
		extensions.Add("VK_EXT_debug_utils");

		List<char8*> layers = scope .();
		if (VALIDATION) layers.Add("VK_LAYER_KHRONOS_validation");

		VkInstanceCreateInfo info = .() {
			pApplicationInfo = &appInfo,
			enabledLayerCount = (.) layers.Count,
			ppEnabledLayerNames = layers.Ptr,
			enabledExtensionCount = (.) extensions.Count,
			ppEnabledExtensionNames = extensions.Ptr
		};

		VkResult result = vkCreateInstance(&info, null, &instance);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create Vulkan instance: {}", result);

		if (VulkanNative.LoadPostInstanceFunctions(instance) == .Err) return Log.ErrorResult("Failed to load Vulkan functions");
		return .Ok;
	}

	typealias DebugCallbackFunction = function VkBool32(VkDebugUtilsMessageSeverityFlagsEXT messageSeverity, VkDebugUtilsMessageTypeFlagsEXT messageType, VkDebugUtilsMessengerCallbackDataEXT* pCallbackData, void* pUserData);

	private Result<void> SetupDebugCallback() {
		DebugCallbackFunction callback = => DebugCallback;

		VkDebugUtilsMessengerCreateInfoEXT info = .() {
			messageSeverity = .VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT | .VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | .VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
			messageType = .VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | .VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | .VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
			pfnUserCallback = callback
		};

		VkResult result = vkCreateDebugUtilsMessengerEXT(instance, &info, null, &messenger);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to setup debug callback");

		return .Ok;
	}

	private static VkBool32 DebugCallback(VkDebugUtilsMessageSeverityFlagsEXT messageSeverity, VkDebugUtilsMessageTypeFlagsEXT messageType, VkDebugUtilsMessengerCallbackDataEXT* pCallbackData, void* pUserData) {
		LogLevel level;

		switch (messageSeverity) {
		case .VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT:	level = .Debug;
		case .VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT:	level = .Warning;
		case .VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT:	level = .Error;
		default:												return false;
		}

		Log.Log(level, .(pCallbackData.pMessage));
		System.Diagnostics.Debug.WriteLine(StringView(pCallbackData.pMessage));

		return false;
	}

	private Result<void> FindPhysicalDevice() {
		uint32 count = 0;
		vkEnumeratePhysicalDevices(instance, &count, null);
		if (count == 0) return Log.ErrorResult("Failed to find a suitable GPU");

		VkPhysicalDevice[] devices = scope .[count];
		vkEnumeratePhysicalDevices(instance, &count, devices.Ptr);

		VkPhysicalDevice lastValidDevice = .Null;
		VkPhysicalDeviceProperties lastValidDeviceProperties = ?;

		for (let device in devices) {
			VkPhysicalDeviceProperties properties = ?;
			vkGetPhysicalDeviceProperties(device, &properties);

			QueueFamilyIndices indices = FindQueueFamilies(device);

			if (indices.Complete) {
				lastValidDevice = device;
				lastValidDeviceProperties = properties;

				if (properties.deviceType == .VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
					break;
				}
			}
		}

		if (lastValidDevice == .Null) {
			return Log.ErrorResult("Failed to find a suitable GPU");
		}

		Log.Info("GPU: {}", lastValidDeviceProperties.deviceName);
		physicalDevice = lastValidDevice;

		return .Ok;
	}

	private Result<void> CreateDevice() {
		QueueFamilyIndices indices = FindQueueFamilies(physicalDevice);

		float priority = 1;

		HashSet<uint32> uniqueQueueFamilies = scope .();
		uniqueQueueFamilies.Add(indices.computeFamily.Value);

		VkDeviceQueueCreateInfo[] queueInfos = scope .[uniqueQueueFamilies.Count];

		int i = 0;
		for (let queueFamily in uniqueQueueFamilies) {
			queueInfos[i] = .() {
				queueFamilyIndex = queueFamily,
				queueCount = 1,
				pQueuePriorities = &priority
			};

			i++;
		}

		VkPhysicalDeviceVulkan12Features features12 = .() {
			hostQueryReset = true,
			runtimeDescriptorArray = true,
			shaderSampledImageArrayNonUniformIndexing = true,
			descriptorBindingPartiallyBound = true
		};

		List<char8*> layers = scope .();
		if (VALIDATION) layers.Add("VK_LAYER_KHRONOS_validation");

		List<char8*> extensions = scope .();
		extensions.Add("VK_KHR_synchronization2");

		VkDeviceCreateInfo info = .() {
			pNext = &features12,
			queueCreateInfoCount = (.) queueInfos.Count,
			pQueueCreateInfos = queueInfos.Ptr,
			enabledLayerCount = (.) layers.Count,
			ppEnabledLayerNames = layers.Ptr,
			enabledExtensionCount = (.) extensions.Count,
			ppEnabledExtensionNames = extensions.Ptr
		};

		VkResult result = vkCreateDevice(physicalDevice, &info, null, &device);
		if (result != .VK_SUCCESS) return Log.ErrorResult("Failed to create Vulkan device");

		vkGetDeviceQueue(device, indices.computeFamily.Value, 0, &computeQueue);
		if (computeQueue == .Null) return Log.ErrorResult("Failed to create Vulkan graphics queue");

		return .Ok;
	}

	private static uint32 Version(uint32 major, uint32 minor, uint32 patch) {
		return (major << 22) | (minor << 12) | patch;
	}

	public struct QueueFamilyIndices {
		public uint32? computeFamily;

		public bool Complete { get {
			return computeFamily.HasValue;
		} }
	}

	public static QueueFamilyIndices FindQueueFamilies(VkPhysicalDevice device) {
		QueueFamilyIndices indices = .();

		uint32 count = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);

		VkQueueFamilyProperties[] families = scope .[count];
		vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families.Ptr);

		uint32 i = 0;
		for (let family in families) {
			if (family.queueFlags & .VK_QUEUE_COMPUTE_BIT != 0) indices.computeFamily = i;
			
			i++;
		}

		return indices;
	}
}