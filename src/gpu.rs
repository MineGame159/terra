use std::{
    cmp::Ordering,
    collections::BTreeMap,
    sync::Arc,
    time::{Duration, Instant},
};

use glam::UVec2;
use smallvec::smallvec;
use vulkano::{
    DeviceSize, VulkanLibrary,
    acceleration_structure::{
        AccelerationStructure, AccelerationStructureBuildGeometryInfo,
        AccelerationStructureBuildRangeInfo, AccelerationStructureBuildType,
        AccelerationStructureCreateInfo, AccelerationStructureGeometries,
        AccelerationStructureGeometryInstancesDataType, AccelerationStructureType,
        BuildAccelerationStructureFlags,
    },
    buffer::{Buffer, BufferContents, BufferCreateInfo, BufferUsage, IndexBuffer, Subbuffer},
    command_buffer::{
        AutoCommandBufferBuilder, CommandBufferUsage, CopyBufferInfo, CopyBufferToImageInfo,
        PrimaryAutoCommandBuffer, allocator::StandardCommandBufferAllocator,
    },
    descriptor_set::{
        allocator::StandardDescriptorSetAllocator,
        layout::{
            DescriptorBindingFlags, DescriptorSetLayout, DescriptorSetLayoutBinding,
            DescriptorSetLayoutCreateInfo, DescriptorType,
        },
    },
    device::{
        Device, DeviceCreateInfo, DeviceExtensions, DeviceFeatures, Queue, QueueCreateInfo,
        QueueFlags,
        physical::{PhysicalDevice, PhysicalDeviceType},
    },
    format::{Format, FormatFeatures, FormatProperties},
    image::{
        Image, ImageCreateInfo, ImageLayout, ImageUsage,
        sampler::{ComponentMapping, ComponentSwizzle},
        view::{ImageView, ImageViewCreateInfo},
    },
    instance::{Instance, InstanceCreateInfo},
    memory::allocator::{AllocationCreateInfo, MemoryTypeFilter, StandardMemoryAllocator},
    shader::ShaderStages,
    sync::{self, GpuFuture},
};

#[derive(Copy, Clone)]
pub struct DescriptorInfo {
    pub stages: ShaderStages,
    pub type_: DescriptorType,
    pub count: u32,
}

pub struct Gpu {
    pub instance: Arc<Instance>,
    pub physical_device: Arc<PhysicalDevice>,
    pub queue_family_index: u32,
    pub device: Arc<Device>,
    pub queue: Arc<Queue>,

    pub memory_allocator: Arc<StandardMemoryAllocator>,
    pub set_allocator: Arc<StandardDescriptorSetAllocator>,
    pub command_allocator: Arc<StandardCommandBufferAllocator>,
}

#[profiling::all_functions]
impl Gpu {
    pub fn new() -> Gpu {
        let vk = VulkanLibrary::new().unwrap();

        let instance = Instance::new(
            vk.clone(),
            InstanceCreateInfo {
                enabled_layers: vec![String::from("VK_LAYER_KHRONOS_validation")],
                ..InstanceCreateInfo::application_from_cargo_toml()
            },
        )
        .unwrap();

        let physical_device = select_physical_device(&instance).unwrap();
        let queue_family_index = find_queue_family_index(&physical_device).unwrap();

        let (device, mut queues_it) = Device::new(
            physical_device.clone(),
            DeviceCreateInfo {
                queue_create_infos: vec![QueueCreateInfo {
                    queue_family_index,
                    queues: vec![1.0],
                    ..Default::default()
                }],
                enabled_extensions: DeviceExtensions {
                    khr_ray_tracing_pipeline: true,
                    khr_acceleration_structure: true,
                    khr_deferred_host_operations: true,
                    ..Default::default()
                },
                enabled_features: DeviceFeatures {
                    descriptor_binding_partially_bound: true,
                    runtime_descriptor_array: true,
                    shader_sampled_image_array_non_uniform_indexing: true,
                    buffer_device_address: true,
                    ray_tracing_pipeline: true,
                    acceleration_structure: true,
                    ..Default::default()
                },
                ..Default::default()
            },
        )
        .unwrap();

        let queue = queues_it.next().unwrap();

        let memory_allocator = Arc::new(StandardMemoryAllocator::new_default(device.clone()));

        let set_allocator = Arc::new(StandardDescriptorSetAllocator::new(
            device.clone(),
            Default::default(),
        ));

        let command_allocator = Arc::new(StandardCommandBufferAllocator::new(
            device.clone(),
            Default::default(),
        ));

        Gpu {
            instance,
            physical_device,
            queue_family_index,
            device,
            queue,

            memory_allocator,
            set_allocator,
            command_allocator,
        }
    }

    pub fn create_buffer<T: BufferContents + Copy>(
        &self,
        usage: BufferUsage,
        memory: MemoryTypeFilter,
        length: DeviceSize,
    ) -> Subbuffer<[T]> {
        Buffer::new_slice(
            self.memory_allocator.clone(),
            BufferCreateInfo {
                usage,
                ..Default::default()
            },
            AllocationCreateInfo {
                memory_type_filter: memory,
                ..Default::default()
            },
            length,
        )
        .unwrap()
    }

    pub fn create_filled_buffer<T: BufferContents + Copy>(
        &self,
        usage: BufferUsage,
        data: &[T],
    ) -> Subbuffer<[T]> {
        let staging_buffer = self.create_buffer(
            usage | BufferUsage::TRANSFER_SRC,
            MemoryTypeFilter::PREFER_HOST | MemoryTypeFilter::HOST_SEQUENTIAL_WRITE,
            data.len() as DeviceSize,
        );

        let buffer = self.create_buffer(
            usage | BufferUsage::TRANSFER_DST,
            MemoryTypeFilter::PREFER_DEVICE,
            data.len() as DeviceSize,
        );

        staging_buffer.write().unwrap().copy_from_slice(data);

        self.execute(|commands| {
            commands
                .copy_buffer(CopyBufferInfo::buffers(staging_buffer, buffer.clone()))
                .unwrap();
        });

        buffer
    }

    pub fn create_image(
        &self,
        size: UVec2,
        format: Format,
        usage: ImageUsage,
    ) -> (Arc<Image>, Arc<ImageView>) {
        let image = Image::new(
            self.memory_allocator.clone(),
            ImageCreateInfo {
                format,
                extent: [size.x, size.y, 1],
                usage,
                initial_layout: ImageLayout::Undefined,
                ..Default::default()
            },
            Default::default(),
        )
        .unwrap();

        let image_view = ImageView::new(
            image.clone(),
            ImageViewCreateInfo {
                component_mapping: match format.components().map(move |bits| bits.min(1)) {
                    [1, 0, 0, 0] => ComponentMapping {
                        r: ComponentSwizzle::Red,
                        g: ComponentSwizzle::Red,
                        b: ComponentSwizzle::Red,
                        a: ComponentSwizzle::Red,
                    },
                    [1, 1, 0, 0] => ComponentMapping {
                        r: ComponentSwizzle::Red,
                        g: ComponentSwizzle::Green,
                        b: ComponentSwizzle::Red,
                        a: ComponentSwizzle::Green,
                    },
                    [1, 1, 1, 1] => ComponentMapping::identity(),
                    _ => unimplemented!(),
                },
                ..ImageViewCreateInfo::from_image(&image)
            },
        )
        .unwrap();

        (image, image_view)
    }

    pub fn create_filled_image(
        &self,
        size: UVec2,
        format: Format,
        usage: ImageUsage,
        pixels: &[u8],
    ) -> (Arc<Image>, Arc<ImageView>) {
        let (image, view) = self.create_image(size, format, usage | ImageUsage::TRANSFER_DST);

        let buffer = self.create_buffer(
            BufferUsage::TRANSFER_SRC,
            MemoryTypeFilter::HOST_SEQUENTIAL_WRITE | MemoryTypeFilter::PREFER_HOST,
            pixels.len() as DeviceSize,
        );

        buffer.write().unwrap().copy_from_slice(pixels);

        self.execute(|commands| {
            commands
                .copy_buffer_to_image(CopyBufferToImageInfo::buffer_image(buffer, image.clone()))
                .unwrap();
        });

        (image, view)
    }

    pub fn create_accel_struct(
        &self,
        bottom_level: bool,
        geometries: AccelerationStructureGeometries,
        commands: &mut AutoCommandBufferBuilder<PrimaryAutoCommandBuffer>,
    ) -> Arc<AccelerationStructure> {
        // Get primitive count

        let primitive_count = match &geometries {
            AccelerationStructureGeometries::Triangles(geometries) => geometries
                .iter()
                .map(move |triangles| match &triangles.index_data {
                    Some(index_buffer) => match index_buffer {
                        IndexBuffer::U8(buffer) => buffer.len() as u32 / 3,
                        IndexBuffer::U16(buffer) => buffer.len() as u32 / 3,
                        IndexBuffer::U32(buffer) => buffer.len() as u32 / 3,
                    },
                    None => (triangles.max_vertex + 1) / 3,
                })
                .sum(),
            AccelerationStructureGeometries::Aabbs(geometries) => geometries
                .iter()
                .map(move |aabbs| {
                    let stride = aabbs.stride;
                    aabbs
                        .data
                        .as_ref()
                        .map_or(0, move |buffer| buffer.len() as u32 / stride)
                })
                .sum(),
            AccelerationStructureGeometries::Instances(geometries) => match &geometries.data {
                AccelerationStructureGeometryInstancesDataType::Values(instances) => instances
                    .as_ref()
                    .map_or(0, move |buffer| buffer.len() as u32),
                AccelerationStructureGeometryInstancesDataType::Pointers(instances) => instances
                    .as_ref()
                    .map_or(0, move |buffer| buffer.len() as u32),
            },
        };

        // Get backing buffer size

        let mut build_info = AccelerationStructureBuildGeometryInfo {
            flags: BuildAccelerationStructureFlags::PREFER_FAST_TRACE,
            dst_acceleration_structure: None,
            scratch_data: None,
            ..AccelerationStructureBuildGeometryInfo::new(geometries)
        };

        let sizes = self
            .device
            .acceleration_structure_build_sizes(
                AccelerationStructureBuildType::Host,
                &build_info,
                &[primitive_count],
            )
            .unwrap();

        // Create backing buffer

        let backing_buffer = self.create_buffer(
            BufferUsage::ACCELERATION_STRUCTURE_STORAGE | BufferUsage::SHADER_DEVICE_ADDRESS,
            MemoryTypeFilter::PREFER_DEVICE,
            sizes.acceleration_structure_size,
        );

        // Create acceleration structure

        let accel_struct = unsafe {
            AccelerationStructure::new(
                self.device.clone(),
                AccelerationStructureCreateInfo {
                    ty: if bottom_level {
                        AccelerationStructureType::BottomLevel
                    } else {
                        AccelerationStructureType::TopLevel
                    },
                    ..AccelerationStructureCreateInfo::new(backing_buffer)
                },
            )
            .unwrap()
        };

        // Build acceleration structure

        let props = self.physical_device.properties();

        let scratch_alignment = props
            .min_acceleration_structure_scratch_offset_alignment
            .unwrap_or(0) as u64;

        let scratch_buffer = self.create_buffer(
            BufferUsage::STORAGE_BUFFER | BufferUsage::SHADER_DEVICE_ADDRESS,
            MemoryTypeFilter::PREFER_DEVICE,
            sizes.build_scratch_size + scratch_alignment,
        );

        build_info.dst_acceleration_structure = Some(accel_struct.clone());
        build_info.scratch_data = Some(align_up(scratch_buffer, scratch_alignment));

        unsafe {
            commands
                .build_acceleration_structure(
                    build_info,
                    smallvec![AccelerationStructureBuildRangeInfo {
                        primitive_count,
                        primitive_offset: 0,
                        first_vertex: 0,
                        transform_offset: 0,
                    }],
                )
                .unwrap();
        }

        accel_struct
    }

    pub fn create_set_layout<'a>(
        &self,
        descriptors: impl IntoIterator<Item = &'a DescriptorInfo>,
    ) -> Arc<DescriptorSetLayout> {
        let mut bindings = BTreeMap::new();
        let mut index = 0u32;

        for descriptor in descriptors {
            bindings.insert(
                index,
                DescriptorSetLayoutBinding {
                    stages: descriptor.stages,
                    binding_flags: if descriptor.count > 1 {
                        DescriptorBindingFlags::PARTIALLY_BOUND
                    } else {
                        DescriptorBindingFlags::empty()
                    },
                    descriptor_count: descriptor.count,
                    ..DescriptorSetLayoutBinding::descriptor_type(descriptor.type_)
                },
            );

            index += 1;
        }

        DescriptorSetLayout::new(
            self.device.clone(),
            DescriptorSetLayoutCreateInfo {
                bindings,
                ..Default::default()
            },
        )
        .unwrap()
    }

    pub fn execute<T>(
        &self,
        build: impl FnOnce(&mut AutoCommandBufferBuilder<PrimaryAutoCommandBuffer>) -> T,
    ) -> (T, Duration) {
        let mut commands = AutoCommandBufferBuilder::primary(
            self.command_allocator.clone(),
            self.queue_family_index.clone(),
            CommandBufferUsage::OneTimeSubmit,
        )
        .unwrap();

        let result = build(&mut commands);

        let command_buffer = commands.build().unwrap();

        let start = Instant::now();

        {
            profiling::scope!("GPU execution");
            sync::now(self.device.clone())
                .then_execute(self.queue.clone(), command_buffer)
                .unwrap()
                .then_signal_fence_and_flush()
                .unwrap()
                .wait(None)
                .unwrap();
        }

        let duration = Instant::now() - start;

        (result, duration)
    }

    pub fn does_format_support(&self, format: Format, features: FormatFeatures) -> bool {
        match self.physical_device.format_properties(format) {
            Ok(props) => props.optimal_tiling_features.contains(features),
            Err(_) => false,
        }
    }
}

fn align_up(buffer: Subbuffer<[u8]>, alignment: DeviceSize) -> Subbuffer<[u8]> {
    let address: DeviceSize = buffer.device_address().unwrap().into();
    let remainder = address % alignment;

    let padding = if remainder == 0 {
        0
    } else {
        alignment - remainder
    };

    buffer.slice(padding..)
}

fn select_physical_device(instance: &Arc<Instance>) -> Option<Arc<PhysicalDevice>> {
    let mut physical_devices: Vec<Arc<PhysicalDevice>> =
        instance.enumerate_physical_devices().unwrap().collect();

    if physical_devices.is_empty() {
        return None;
    }

    physical_devices.sort_by(move |a, b| {
        let a_gpu = a.properties().device_type == PhysicalDeviceType::DiscreteGpu;
        let b_gpu = b.properties().device_type == PhysicalDeviceType::DiscreteGpu;

        if a_gpu == b_gpu {
            Ordering::Equal
        } else if a_gpu {
            Ordering::Greater
        } else {
            Ordering::Less
        }
    });

    Some(physical_devices[0].clone())
}

fn find_queue_family_index(physical_device: &PhysicalDevice) -> Option<u32> {
    physical_device
        .queue_family_properties()
        .iter()
        .position(move |props| props.queue_flags.contains(QueueFlags::COMPUTE))
        .map(move |i| i as u32)
}
