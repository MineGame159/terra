#![feature(iter_array_chunks)]

use glam::{FloatExt, Mat4, Quat, U8Vec3, Vec3, Vec4};
use gltf::Node;
use gltf::mesh::Mode;
use gltf::mesh::util::ReadIndices;
use gltf::scene::Transform;
use png::{BitDepth, ColorType};
use smallvec::smallvec;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;
use std::sync::Arc;
use vulkano::acceleration_structure::{
    AccelerationStructure, AccelerationStructureBuildGeometryInfo,
    AccelerationStructureBuildRangeInfo, AccelerationStructureBuildType,
    AccelerationStructureCreateInfo, AccelerationStructureGeometries,
    AccelerationStructureGeometryInstancesData, AccelerationStructureGeometryInstancesDataType,
    AccelerationStructureGeometryTrianglesData, AccelerationStructureInstance,
    AccelerationStructureType, BuildAccelerationStructureFlags, GeometryFlags,
    GeometryInstanceFlags,
};
use vulkano::buffer::{Buffer, BufferContents, BufferCreateInfo, BufferUsage, Subbuffer};
use vulkano::command_buffer::allocator::StandardCommandBufferAllocator;
use vulkano::command_buffer::{
    AutoCommandBufferBuilder, CommandBufferUsage, CopyImageToBufferInfo, PrimaryAutoCommandBuffer,
};
use vulkano::descriptor_set::allocator::StandardDescriptorSetAllocator;
use vulkano::descriptor_set::layout::{
    DescriptorSetLayout, DescriptorSetLayoutBinding, DescriptorSetLayoutCreateInfo, DescriptorType,
};
use vulkano::descriptor_set::{DescriptorImageViewInfo, DescriptorSet, WriteDescriptorSet};
use vulkano::device::physical::{PhysicalDevice, PhysicalDeviceType};
use vulkano::device::{
    Device, DeviceCreateInfo, DeviceExtensions, DeviceFeatures, DeviceOwned, Queue,
    QueueCreateInfo, QueueFlags,
};
use vulkano::format::Format;
use vulkano::image::view::{ImageView, ImageViewCreateInfo};
use vulkano::image::{Image, ImageCreateInfo, ImageLayout, ImageUsage};
use vulkano::instance::{Instance, InstanceCreateInfo};
use vulkano::memory::allocator::{
    AllocationCreateInfo, DeviceLayout, MemoryAllocator, MemoryTypeFilter, StandardMemoryAllocator,
};
use vulkano::pipeline::layout::{PipelineLayoutCreateInfo, PushConstantRange};
use vulkano::pipeline::ray_tracing::{
    RayTracingPipeline, RayTracingPipelineCreateInfo, RayTracingShaderGroupCreateInfo,
    ShaderBindingTable,
};
use vulkano::pipeline::{PipelineBindPoint, PipelineLayout, PipelineShaderStageCreateInfo};
use vulkano::shader::{ShaderModule, ShaderModuleCreateInfo, ShaderStages, spirv};
use vulkano::sync::GpuFuture;
use vulkano::{DeviceSize, Packed24_8, VulkanLibrary, sync};

const SPV_RAY: &'static [u8] = include_bytes!(concat!(env!("OUT_DIR"), "/shaders/ray.spv"));

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct Vertex {
    position: Vec4,
    normal: Vec4,
}

#[derive(BufferContents, Copy, Clone)]
#[repr(transparent)]
struct Triangle([Vertex; 3]);

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct Camera {
    origin: Vec4,
    lower_left_corner: Vec4,
    horizontal: Vec4,
    vertical: Vec4,
}

impl Camera {
    fn new(pos: Vec3, look_at: Vec3, fov: f32, aspect_ratio: f32) -> Camera {
        let theta = fov.to_radians();
        let h = (theta / 2.0).tan();
        let viewport_height = 2.0 * h;
        let viewport_width = aspect_ratio * viewport_height;

        let w = (pos - look_at).normalize();
        let u = Vec3::Y.cross(w).normalize();
        let v = w.cross(u);

        Camera {
            origin: pos.extend(0.0),
            horizontal: (viewport_width * u).extend(0.0),
            vertical: (viewport_height * v).extend(0.0),
            lower_left_corner: (pos - (viewport_width * u) / 2.0 - (viewport_height * v) / 2.0 - w)
                .extend(0.0),
        }
    }
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct PushConstants {
    camera: Camera,
    width: u32,
    height: u32,
    bounces: u32,
    sample: u32,
}

fn main() {
    let vk = VulkanLibrary::new().unwrap();
    let instance = Instance::new(vk, InstanceCreateInfo::application_from_cargo_toml()).unwrap();
    let physical_device = select_physical_device(&instance).unwrap();
    let queue_family_index = find_queue_family_index(&physical_device).unwrap();

    let (device, queues_it) = Device::new(
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

    let queues: Vec<Arc<Queue>> = queues_it.collect();

    let allocator = Arc::new(StandardMemoryAllocator::new_default(device.clone()));

    let set_allocator = Arc::new(StandardDescriptorSetAllocator::new(
        device.clone(),
        Default::default(),
    ));

    let command_allocator = Arc::new(StandardCommandBufferAllocator::new(
        device.clone(),
        Default::default(),
    ));

    let module = unsafe {
        ShaderModule::new(
            device.clone(),
            ShaderModuleCreateInfo::new(&spirv::bytes_to_words(SPV_RAY).unwrap()),
        )
        .unwrap()
    };

    let mut bindings = BTreeMap::new();

    bindings.insert(
        0,
        DescriptorSetLayoutBinding {
            stages: ShaderStages::RAYGEN,
            ..DescriptorSetLayoutBinding::descriptor_type(DescriptorType::AccelerationStructure)
        },
    );
    bindings.insert(
        1,
        DescriptorSetLayoutBinding {
            stages: ShaderStages::CLOSEST_HIT,
            ..DescriptorSetLayoutBinding::descriptor_type(DescriptorType::StorageBuffer)
        },
    );
    bindings.insert(
        2,
        DescriptorSetLayoutBinding {
            stages: ShaderStages::RAYGEN,
            ..DescriptorSetLayoutBinding::descriptor_type(DescriptorType::StorageImage)
        },
    );

    let set_layout = DescriptorSetLayout::new(
        device.clone(),
        DescriptorSetLayoutCreateInfo {
            bindings,
            ..Default::default()
        },
    )
    .unwrap();

    let layout = PipelineLayout::new(
        device.clone(),
        PipelineLayoutCreateInfo {
            set_layouts: vec![set_layout.clone()],
            push_constant_ranges: vec![PushConstantRange {
                stages: ShaderStages::RAYGEN,
                offset: 0,
                size: size_of::<PushConstants>() as u32,
            }],
            ..Default::default()
        },
    )
    .unwrap();

    let pipeline = RayTracingPipeline::new(
        device.clone(),
        None,
        RayTracingPipelineCreateInfo {
            stages: smallvec![
                PipelineShaderStageCreateInfo::new(module.entry_point("RayGen").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("Miss").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("ClosestHit").unwrap()),
            ],
            groups: smallvec![
                RayTracingShaderGroupCreateInfo::General { general_shader: 0 },
                RayTracingShaderGroupCreateInfo::General { general_shader: 1 },
                RayTracingShaderGroupCreateInfo::TrianglesHit {
                    closest_hit_shader: Some(2),
                    any_hit_shader: None
                },
            ],
            max_pipeline_ray_recursion_depth: 1,
            ..RayTracingPipelineCreateInfo::layout(layout.clone())
        },
    )
    .unwrap();

    let shader_binding_table = ShaderBindingTable::new(allocator.clone(), &pipeline).unwrap();

    let triangles = load_model("models/monkey.glb");

    let triangle_buffer = create_buffer(
        allocator.clone(),
        BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
            | BufferUsage::SHADER_DEVICE_ADDRESS
            | BufferUsage::STORAGE_BUFFER,
        &triangles,
    );

    let bottom_accel_struct = execute(
        queues[0].clone(),
        command_allocator.clone(),
        queue_family_index,
        |commands| create_bottom_accel_struct(allocator.clone(), commands, triangle_buffer.clone()),
    );

    let top_accel_struct = execute(
        queues[0].clone(),
        command_allocator.clone(),
        queue_family_index,
        |commands| {
            create_top_accel_struct(
                allocator.clone(),
                commands,
                &[AccelerationStructureInstance {
                    instance_shader_binding_table_record_offset_and_flags: Packed24_8::new(
                        0,
                        GeometryInstanceFlags::TRIANGLE_FACING_CULL_DISABLE.into(),
                    ),
                    acceleration_structure_reference: bottom_accel_struct.device_address().into(),
                    ..Default::default()
                }],
            )
        },
    );

    let image = Image::new(
        allocator.clone(),
        ImageCreateInfo {
            format: Format::R32G32B32A32_SFLOAT,
            extent: [1280, 720, 1],
            usage: ImageUsage::STORAGE | ImageUsage::TRANSFER_SRC,
            initial_layout: ImageLayout::Undefined,
            ..Default::default()
        },
        Default::default(),
    )
    .unwrap();

    let image_view =
        ImageView::new(image.clone(), ImageViewCreateInfo::from_image(&image)).unwrap();

    let set = DescriptorSet::new(
        set_allocator.clone(),
        set_layout.clone(),
        [
            WriteDescriptorSet::acceleration_structure(0, top_accel_struct.clone()),
            WriteDescriptorSet::buffer(1, triangle_buffer),
            WriteDescriptorSet::image_view_with_layout(
                2,
                DescriptorImageViewInfo {
                    image_view: image_view.clone(),
                    image_layout: ImageLayout::General,
                },
            ),
        ],
        [],
    )
    .unwrap();

    let image_buffer: Subbuffer<[Vec4]> = Buffer::new_slice(
        allocator.clone(),
        BufferCreateInfo {
            usage: BufferUsage::TRANSFER_DST,
            ..Default::default()
        },
        AllocationCreateInfo {
            memory_type_filter: MemoryTypeFilter::HOST_RANDOM_ACCESS,
            ..Default::default()
        },
        1280 * 720,
    )
    .unwrap();

    let mut pc = PushConstants {
        camera: Camera::new(Vec3::new(2.0, 1.0, 2.0), Vec3::ZERO, 70.0, 1280.0 / 720.0),
        width: 1280,
        height: 720,
        bounces: 6,
        sample: 0,
    };

    for _ in 0..64 {
        execute(
            queues[0].clone(),
            command_allocator.clone(),
            queue_family_index,
            |commands| {
                commands
                    .bind_pipeline_ray_tracing(pipeline.clone())
                    .unwrap();

                commands
                    .bind_descriptor_sets(
                        PipelineBindPoint::RayTracing,
                        layout.clone(),
                        0,
                        set.clone(),
                    )
                    .unwrap();

                commands.push_constants(layout.clone(), 0, pc).unwrap();

                unsafe {
                    commands
                        .trace_rays(shader_binding_table.addresses().clone(), [1280, 720, 1])
                        .unwrap();
                }
            },
        );

        pc.sample += 1;
    }

    execute(
        queues[0].clone(),
        command_allocator.clone(),
        queue_family_index,
        |commands| {
            commands
                .copy_image_to_buffer(CopyImageToBufferInfo::image_buffer(
                    image.clone(),
                    image_buffer.clone(),
                ))
                .unwrap();
        },
    );

    let pixels: Vec<U8Vec3> = image_buffer
        .read()
        .unwrap()
        .iter()
        .map(move |color| {
            let mut color = Vec3::new(color.x, color.y, color.z).max(Vec3::ZERO);
            color = reinhard_jodie(color);

            const GAMMA: f32 = 2.2;
            color = color.powf(1.0 / GAMMA);

            U8Vec3::new(
                (color.x.clamp(0.0, 0.999) * 255.0) as u8,
                (color.y.clamp(0.0, 0.999) * 255.0) as u8,
                (color.z.clamp(0.0, 0.999) * 255.0) as u8,
            )
        })
        .collect();

    let file = File::create("image.png").unwrap();
    let writer = BufWriter::new(file);

    let mut encoder = png::Encoder::new(writer, 1280, 720);
    encoder.set_color(ColorType::Rgb);
    encoder.set_depth(BitDepth::Eight);

    encoder
        .write_header()
        .unwrap()
        .write_image_data(bytemuck::cast_slice(&pixels))
        .unwrap();

    println!("Device: {}", physical_device.properties().device_name);
}

fn luminance(v: Vec3) -> f32 {
    v.dot(Vec3::new(0.2126, 0.7152, 0.0722))
}

fn reinhard_jodie(v: Vec3) -> Vec3 {
    let l = luminance(v);
    let tv = v / (Vec3::ONE + v);
    let from = v / (1.0 + l);

    Vec3::new(
        from.x.lerp(tv.x, tv.x),
        from.y.lerp(tv.y, tv.y),
        from.z.lerp(tv.z, tv.z),
    )
}

fn load_model(path: impl AsRef<Path>) -> Vec<Triangle> {
    fn load_node(
        buffers: &Vec<gltf::buffer::Data>,
        triangles: &mut Vec<Triangle>,
        global_transform: Mat4,
        node: Node,
    ) {
        let local_transform = match node.transform() {
            Transform::Matrix { matrix } => Mat4::from_cols_array_2d(&matrix),
            Transform::Decomposed {
                translation,
                rotation,
                scale,
            } => Mat4::from_scale_rotation_translation(
                Vec3::from_array(scale),
                Quat::from_array(rotation),
                Vec3::from_array(translation),
            ),
        };

        let transform = global_transform * local_transform;

        if let Some(mesh) = node.mesh() {
            for primitive in mesh.primitives() {
                if primitive.mode() != Mode::Triangles {
                    continue;
                }

                let reader = primitive.reader(move |buffer| Some(&buffers[buffer.index()]));

                let positions: Vec<Vec3> = reader
                    .read_positions()
                    .unwrap()
                    .map(|pos| transform.transform_point3(Vec3::from_array(pos)))
                    .collect();

                let normals: Vec<Vec3> = reader
                    .read_normals()
                    .unwrap()
                    .map(|normal| transform.transform_vector3(Vec3::from_array(normal)))
                    .collect();

                let indices: Vec<u32> = match reader.read_indices().unwrap() {
                    ReadIndices::U8(iter) => iter.map(move |i| i as u32).collect(),
                    ReadIndices::U16(iter) => iter.map(move |i| i as u32).collect(),
                    ReadIndices::U32(iter) => iter.collect(),
                };

                triangles.extend(
                    indices
                        .iter()
                        .map(|i| Vertex {
                            position: positions[*i as usize].extend(0.0),
                            normal: normals[*i as usize].extend(0.0),
                        })
                        .array_chunks::<3>()
                        .map(|vertices| Triangle(vertices)),
                );
            }
        }

        for child in node.children() {
            load_node(buffers, triangles, transform, child);
        }
    }

    let (document, buffers, _images) = gltf::import(path).unwrap();

    let mut triangles: Vec<Triangle> = vec![];

    for node in document.default_scene().unwrap().nodes() {
        load_node(&buffers, &mut triangles, Mat4::IDENTITY, node);
    }

    triangles
}

fn create_bottom_accel_struct<T>(
    allocator: Arc<dyn MemoryAllocator>,
    commands: &mut AutoCommandBufferBuilder<T>,
    triangle_buffer: Subbuffer<[Triangle]>,
) -> Arc<AccelerationStructure> {
    // Get backing buffer size

    let mut build_info = AccelerationStructureBuildGeometryInfo {
        flags: BuildAccelerationStructureFlags::PREFER_FAST_TRACE,
        dst_acceleration_structure: None,
        scratch_data: None,
        ..AccelerationStructureBuildGeometryInfo::new(AccelerationStructureGeometries::Triangles(
            vec![AccelerationStructureGeometryTrianglesData {
                flags: GeometryFlags::OPAQUE,
                vertex_data: Some(triangle_buffer.clone().into_bytes()),
                vertex_stride: size_of::<Vertex>() as u32,
                max_vertex: (triangle_buffer.len() * 3 - 1) as u32,
                index_data: None,
                transform_data: None,
                ..AccelerationStructureGeometryTrianglesData::new(Format::R32G32B32_SFLOAT)
            }],
        ))
    };

    let sizes = commands
        .device()
        .acceleration_structure_build_sizes(
            AccelerationStructureBuildType::Host,
            &build_info,
            &[triangle_buffer.len() as u32],
        )
        .unwrap();

    // Create backing buffer

    let buffer = Buffer::new(
        allocator.clone(),
        BufferCreateInfo {
            usage: BufferUsage::ACCELERATION_STRUCTURE_STORAGE,
            ..Default::default()
        },
        AllocationCreateInfo {
            memory_type_filter: MemoryTypeFilter::PREFER_DEVICE,
            ..Default::default()
        },
        DeviceLayout::from_size_alignment(sizes.acceleration_structure_size, 8).unwrap(),
    )
    .unwrap();

    // Create acceleration structure

    let accel_struct = unsafe {
        AccelerationStructure::new(
            commands.device().clone(),
            AccelerationStructureCreateInfo {
                ty: AccelerationStructureType::BottomLevel,
                ..AccelerationStructureCreateInfo::new(Subbuffer::new(buffer.clone()))
            },
        )
        .unwrap()
    };

    // Build acceleration structure

    let scratch_buffer = Buffer::new_slice(
        allocator.clone(),
        BufferCreateInfo {
            usage: BufferUsage::STORAGE_BUFFER | BufferUsage::SHADER_DEVICE_ADDRESS,
            ..Default::default()
        },
        AllocationCreateInfo {
            memory_type_filter: MemoryTypeFilter::PREFER_DEVICE,
            ..Default::default()
        },
        sizes.build_scratch_size,
    )
    .unwrap();

    build_info.dst_acceleration_structure = Some(accel_struct.clone());
    build_info.scratch_data = Some(scratch_buffer);

    unsafe {
        commands
            .build_acceleration_structure(
                build_info,
                smallvec![AccelerationStructureBuildRangeInfo {
                    primitive_count: triangle_buffer.len() as u32,
                    ..Default::default()
                }],
            )
            .unwrap();
    }

    accel_struct
}

fn create_top_accel_struct<T>(
    allocator: Arc<dyn MemoryAllocator>,
    commands: &mut AutoCommandBufferBuilder<T>,
    instances: &[AccelerationStructureInstance],
) -> Arc<AccelerationStructure> {
    // Upload input buffer

    let instance_buffer = create_buffer(
        allocator.clone(),
        BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
            | BufferUsage::SHADER_DEVICE_ADDRESS,
        instances,
    );

    // Get backing buffer size

    let mut build_info = AccelerationStructureBuildGeometryInfo {
        flags: BuildAccelerationStructureFlags::PREFER_FAST_TRACE,
        ..AccelerationStructureBuildGeometryInfo::new(AccelerationStructureGeometries::Instances(
            AccelerationStructureGeometryInstancesData {
                flags: GeometryFlags::OPAQUE,
                ..AccelerationStructureGeometryInstancesData::new(
                    AccelerationStructureGeometryInstancesDataType::Values(Some(instance_buffer)),
                )
            },
        ))
    };

    let sizes = commands
        .device()
        .acceleration_structure_build_sizes(
            AccelerationStructureBuildType::Host,
            &build_info,
            &[instances.len() as u32],
        )
        .unwrap();

    // Create backing buffer

    let buffer = Buffer::new(
        allocator.clone(),
        BufferCreateInfo {
            usage: BufferUsage::ACCELERATION_STRUCTURE_STORAGE,
            ..Default::default()
        },
        AllocationCreateInfo {
            memory_type_filter: MemoryTypeFilter::PREFER_DEVICE,
            ..Default::default()
        },
        DeviceLayout::from_size_alignment(sizes.acceleration_structure_size, 8).unwrap(),
    )
    .unwrap();

    // Create acceleration structure

    let accel_struct = unsafe {
        AccelerationStructure::new(
            commands.device().clone(),
            AccelerationStructureCreateInfo {
                ty: AccelerationStructureType::TopLevel,
                ..AccelerationStructureCreateInfo::new(Subbuffer::new(buffer.clone()))
            },
        )
        .unwrap()
    };

    // Build acceleration structure

    let scratch_buffer = Buffer::new_slice(
        allocator.clone(),
        BufferCreateInfo {
            usage: BufferUsage::STORAGE_BUFFER | BufferUsage::SHADER_DEVICE_ADDRESS,
            ..Default::default()
        },
        AllocationCreateInfo {
            memory_type_filter: MemoryTypeFilter::PREFER_DEVICE,
            ..Default::default()
        },
        sizes.build_scratch_size,
    )
    .unwrap();

    build_info.dst_acceleration_structure = Some(accel_struct.clone());
    build_info.scratch_data = Some(scratch_buffer);

    unsafe {
        commands
            .build_acceleration_structure(
                build_info,
                smallvec![AccelerationStructureBuildRangeInfo {
                    primitive_count: instances.len() as u32,
                    ..Default::default()
                }],
            )
            .unwrap();
    }

    accel_struct
}

fn create_buffer<T: BufferContents + Copy>(
    allocator: Arc<dyn MemoryAllocator>,
    usage: BufferUsage,
    data: &[T],
) -> Subbuffer<[T]> {
    let buffer = Buffer::new_slice(
        allocator,
        BufferCreateInfo {
            usage,
            ..Default::default()
        },
        AllocationCreateInfo {
            memory_type_filter: MemoryTypeFilter::PREFER_DEVICE
                | MemoryTypeFilter::HOST_SEQUENTIAL_WRITE,
            ..Default::default()
        },
        data.len() as DeviceSize,
    )
    .unwrap();

    buffer.write().unwrap().copy_from_slice(data);

    buffer
}

fn execute<T>(
    queue: Arc<Queue>,
    command_allocator: Arc<StandardCommandBufferAllocator>,
    queue_family_index: u32,
    build: impl FnOnce(&mut AutoCommandBufferBuilder<PrimaryAutoCommandBuffer>) -> T,
) -> T {
    let mut commands = AutoCommandBufferBuilder::primary(
        command_allocator,
        queue_family_index,
        CommandBufferUsage::OneTimeSubmit,
    )
    .unwrap();

    let result = build(&mut commands);

    let command_buffer = commands.build().unwrap();

    sync::now(queue.device().clone())
        .then_execute(queue, command_buffer)
        .unwrap()
        .then_signal_fence_and_flush()
        .unwrap()
        .wait(None)
        .unwrap();

    result
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

fn find_queue_family_index(physical_device: &Arc<PhysicalDevice>) -> Option<u32> {
    physical_device
        .queue_family_properties()
        .iter()
        .position(move |props| props.queue_flags.contains(QueueFlags::COMPUTE))
        .map(move |i| i as u32)
}
