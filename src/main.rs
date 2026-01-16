#![feature(iter_array_chunks)]

mod gpu;
mod scene;

use crate::gpu::{DescriptorInfo, Gpu};
use crate::scene::{CameraData, SceneBuilder};
use glam::{FloatExt, U8Vec3, Vec3, Vec4, uvec2, vec3, Mat4};
use png::{BitDepth, ColorType};
use smallvec::smallvec;
use std::fs::File;
use std::io::BufWriter;
use std::sync::Arc;
use vulkano::buffer::{BufferContents, BufferUsage, Subbuffer};
use vulkano::command_buffer::CopyImageToBufferInfo;
use vulkano::descriptor_set::layout::{DescriptorSetLayout, DescriptorType};
use vulkano::descriptor_set::{DescriptorImageViewInfo, DescriptorSet, WriteDescriptorSet};
use vulkano::format::Format;
use vulkano::image::{ImageLayout, ImageUsage};
use vulkano::memory::allocator::MemoryTypeFilter;
use vulkano::pipeline::layout::{PipelineLayoutCreateInfo, PushConstantRange};
use vulkano::pipeline::ray_tracing::{
    RayTracingPipeline, RayTracingPipelineCreateInfo, RayTracingShaderGroupCreateInfo,
    ShaderBindingTable,
};
use vulkano::pipeline::{
    Pipeline, PipelineBindPoint, PipelineLayout, PipelineShaderStageCreateInfo,
};
use vulkano::shader::{ShaderModule, ShaderModuleCreateInfo, ShaderStages, spirv};

const SPV_RAY: &'static [u8] = include_bytes!(concat!(env!("OUT_DIR"), "/shaders/ray.spv"));

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
pub struct Camera {
    pub origin: Vec4,
    pub lower_left_corner: Vec4,
    pub horizontal: Vec4,
    pub vertical: Vec4,
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

impl Camera {
    pub fn new(data: CameraData, aspect_ratio: f32) -> Camera {
        let theta = data.fov.to_radians();
        let h = (theta / 2.0).tan();
        let viewport_height = 2.0 * h;
        let viewport_width = aspect_ratio * viewport_height;

        let w = (data.position - data.look_at).normalize();
        let u = Vec3::Y.cross(w).normalize();
        let v = w.cross(u);

        Camera {
            origin: data.position.extend(0.0),
            horizontal: (viewport_width * u).extend(0.0),
            vertical: (viewport_height * v).extend(0.0),
            lower_left_corner: (data.position
                - (viewport_width * u) / 2.0
                - (viewport_height * v) / 2.0
                - w)
                .extend(0.0),
        }
    }
}

fn main() {
    // Create gpu

    let gpu = Gpu::new();

    // Create pipeline

    let set_layout = gpu.create_set_layout(&[
        DescriptorInfo {
            stages: ShaderStages::RAYGEN,
            type_: DescriptorType::AccelerationStructure,
        },
        DescriptorInfo {
            stages: ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::StorageBuffer,
        },
        DescriptorInfo {
            stages: ShaderStages::RAYGEN,
            type_: DescriptorType::StorageImage,
        },
    ]);

    let (pipeline, shader_binding_table) = create_pipeline(&gpu, set_layout.clone());

    // Load scene

    let mut scene_builder = SceneBuilder::new();
    scene_builder.load_model("models/monkey.glb", Mat4::IDENTITY);

    let scene = scene_builder.build(&gpu);

    // Create set

    let (image, image_view) = gpu.create_image(
        uvec2(1280, 720),
        Format::R32G32B32A32_SFLOAT,
        ImageUsage::STORAGE | ImageUsage::TRANSFER_SRC,
    );

    let set = DescriptorSet::new(
        gpu.set_allocator.clone(),
        set_layout.clone(),
        [
            WriteDescriptorSet::acceleration_structure(0, scene.accel_struct.clone()),
            WriteDescriptorSet::buffer(1, scene.triangle_buffer.clone()),
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

    // Render

    let mut pc = PushConstants {
        camera: Camera::new(
            CameraData {
                position: vec3(2.0, 1.0, 2.0),
                look_at: Vec3::ZERO,
                fov: 70.0,
            },
            1280.0 / 720.0,
        ),
        width: 1280,
        height: 720,
        bounces: 6,
        sample: 0,
    };

    for _ in 0..64 {
        gpu.execute(|commands| {
            commands
                .bind_pipeline_ray_tracing(pipeline.clone())
                .unwrap();

            commands
                .bind_descriptor_sets(
                    PipelineBindPoint::RayTracing,
                    pipeline.layout().clone(),
                    0,
                    set.clone(),
                )
                .unwrap();

            commands
                .push_constants(pipeline.layout().clone(), 0, pc)
                .unwrap();

            unsafe {
                commands
                    .trace_rays(shader_binding_table.addresses().clone(), [1280, 720, 1])
                    .unwrap();
            }
        });

        pc.sample += 1;
    }

    // Copy image to buffer

    let image_buffer: Subbuffer<[Vec4]> = gpu.create_buffer(
        BufferUsage::TRANSFER_DST,
        MemoryTypeFilter::HOST_RANDOM_ACCESS,
        1280 * 720,
    );

    gpu.execute(|commands| {
        commands
            .copy_image_to_buffer(CopyImageToBufferInfo::image_buffer(
                image.clone(),
                image_buffer.clone(),
            ))
            .unwrap();
    });

    // Read image buffer

    let pixels: Vec<U8Vec3> = image_buffer.read().unwrap().iter().map(map_color).collect();

    // Write pixels to image

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

fn map_color(color: &Vec4) -> U8Vec3 {
    let mut color = Vec3::new(color.x, color.y, color.z).max(Vec3::ZERO);
    color = reinhard_jodie(color);

    const GAMMA: f32 = 2.2;
    color = color.powf(1.0 / GAMMA);

    U8Vec3::new(
        (color.x.clamp(0.0, 0.999) * 255.0) as u8,
        (color.y.clamp(0.0, 0.999) * 255.0) as u8,
        (color.z.clamp(0.0, 0.999) * 255.0) as u8,
    )
}

fn create_pipeline(
    gpu: &Gpu,
    set_layout: Arc<DescriptorSetLayout>,
) -> (Arc<RayTracingPipeline>, ShaderBindingTable) {
    let module = unsafe {
        ShaderModule::new(
            gpu.device.clone(),
            ShaderModuleCreateInfo::new(&spirv::bytes_to_words(SPV_RAY).unwrap()),
        )
        .unwrap()
    };

    let layout = PipelineLayout::new(
        gpu.device.clone(),
        PipelineLayoutCreateInfo {
            set_layouts: vec![set_layout],
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
        gpu.device.clone(),
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

    let shader_binding_table =
        ShaderBindingTable::new(gpu.memory_allocator.clone(), &pipeline).unwrap();

    (pipeline, shader_binding_table)
}
