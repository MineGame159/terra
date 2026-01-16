use glam::UVec2;
use smallvec::smallvec;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::sync::Arc;
use vulkano::acceleration_structure::{
    AccelerationStructure, AccelerationStructureBuildGeometryInfo,
    AccelerationStructureBuildRangeInfo, AccelerationStructureBuildType,
    AccelerationStructureCreateInfo, AccelerationStructureGeometries,
    AccelerationStructureGeometryInstancesDataType, AccelerationStructureType,
    BuildAccelerationStructureFlags,
};
use vulkano::buffer::{Buffer, BufferContents, BufferCreateInfo, BufferUsage, Subbuffer};
use vulkano::command_buffer::allocator::StandardCommandBufferAllocator;
use vulkano::command_buffer::{
    AutoCommandBufferBuilder, CommandBufferUsage, PrimaryAutoCommandBuffer,
};
use vulkano::descriptor_set::allocator::StandardDescriptorSetAllocator;
use vulkano::descriptor_set::layout::{
    DescriptorSetLayout, DescriptorSetLayoutBinding, DescriptorSetLayoutCreateInfo, DescriptorType,
};
use vulkano::device::physical::{PhysicalDevice, PhysicalDeviceType};
use vulkano::device::{
    Device, DeviceCreateInfo, DeviceExtensions, DeviceFeatures, Queue, QueueCreateInfo, QueueFlags,
};
use vulkano::format::Format;
use vulkano::image::view::{ImageView, ImageViewCreateInfo};
use vulkano::image::{Image, ImageCreateInfo, ImageLayout, ImageUsage};
use vulkano::instance::{Instance, InstanceCreateInfo};
use vulkano::memory::allocator::{AllocationCreateInfo, MemoryTypeFilter, StandardMemoryAllocator};
use vulkano::shader::ShaderStages;
use vulkano::sync::GpuFuture;
use vulkano::{DeviceSize, VulkanLibrary, sync};

#[derive(Copy, Clone)]
pub struct DescriptorInfo {
    pub stages: ShaderStages,
    pub type_: DescriptorType,
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

impl Gpu {
    pub fn new() -> Gpu {
        let vk = VulkanLibrary::new().unwrap();
        let instance = Instance::new(
            vk.clone(),
            InstanceCreateInfo::application_from_cargo_toml(),
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
                    ..Default::default()
                },
                enabled_features: DeviceFeatures {
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

        println!("Device: {}", physical_device.properties().device_name);

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
        let buffer = self.create_buffer(
            usage,
            MemoryTypeFilter::PREFER_DEVICE | MemoryTypeFilter::HOST_SEQUENTIAL_WRITE,
            data.len() as DeviceSize,
        );

        buffer.write().unwrap().copy_from_slice(data);

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

        let image_view =
            ImageView::new(image.clone(), ImageViewCreateInfo::from_image(&image)).unwrap();

        (image, image_view)
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
                .map(move |triangles| (triangles.max_vertex + 1) / 3)
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
            BufferUsage::ACCELERATION_STRUCTURE_STORAGE,
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

        let scratch_buffer = self.create_buffer(
            BufferUsage::STORAGE_BUFFER | BufferUsage::SHADER_DEVICE_ADDRESS,
            MemoryTypeFilter::PREFER_DEVICE,
            sizes.build_scratch_size,
        );

        build_info.dst_acceleration_structure = Some(accel_struct.clone());
        build_info.scratch_data = Some(scratch_buffer);

        unsafe {
            commands
                .build_acceleration_structure(
                    build_info,
                    smallvec![AccelerationStructureBuildRangeInfo {
                        primitive_count,
                        ..Default::default()
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
    ) -> T {
        let mut commands = AutoCommandBufferBuilder::primary(
            self.command_allocator.clone(),
            self.queue_family_index.clone(),
            CommandBufferUsage::OneTimeSubmit,
        )
        .unwrap();

        let result = build(&mut commands);

        let command_buffer = commands.build().unwrap();

        sync::now(self.device.clone())
            .then_execute(self.queue.clone(), command_buffer)
            .unwrap()
            .then_signal_fence_and_flush()
            .unwrap()
            .wait(None)
            .unwrap();

        result
    }
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
