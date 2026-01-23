#![feature(iter_array_chunks)]

mod color;
mod gpu;
mod model;
mod scene;

use std::{
    fs::{File, read},
    io::BufWriter,
    sync::Arc,
    time::{Duration, Instant},
};

use clap::Parser;
use glam::{Mat4, U8Vec3, UVec2, Vec3, Vec4, uvec2, vec3};
use kdam::tqdm;
use png::{BitDepth, ColorType};
use smallvec::smallvec;
use vulkano::{
    DeviceSize,
    buffer::{BufferContents, BufferUsage, Subbuffer},
    command_buffer::{ClearColorImageInfo, CopyImageToBufferInfo},
    descriptor_set::{
        DescriptorImageViewInfo, DescriptorSet, WriteDescriptorSet,
        layout::{DescriptorSetLayout, DescriptorType},
    },
    format::Format,
    image::{
        ImageLayout, ImageUsage,
        sampler::{Sampler, SamplerCreateInfo},
    },
    memory::allocator::MemoryTypeFilter,
    pipeline::{
        Pipeline, PipelineBindPoint, PipelineLayout, PipelineShaderStageCreateInfo,
        layout::{PipelineLayoutCreateInfo, PushConstantRange},
        ray_tracing::{
            RayTracingPipeline, RayTracingPipelineCreateInfo, RayTracingShaderGroupCreateInfo,
            ShaderBindingTable,
        },
    },
    shader::{ShaderModule, ShaderModuleCreateInfo, ShaderStages, spirv},
};
use zune_hdr::HdrDecoder;

use crate::{
    color::ToneMappingOperator,
    gpu::{DescriptorInfo, Gpu},
    model::load_model,
    scene::{CameraData, SceneBuilder},
};

const SPV_RAY: &'static [u8] = include_bytes!(concat!(env!("OUT_DIR"), "/shaders/ray.spv"));

fn parser_uvec2(str: &str) -> Result<UVec2, String> {
    let mut split = str.split('x');

    if let Some(x_str) = split.next() {
        let x = match x_str.parse::<u32>() {
            Ok(v) => v,
            Err(e) => return Err(format!("{}, expected <WIDTH>x<HEIGHT>", e)),
        };

        if let Some(y_str) = split.next() {
            let y = match y_str.parse::<u32>() {
                Ok(v) => v,
                Err(e) => return Err(format!("{}, expected <WIDTH>x<HEIGHT>", e)),
            };

            return Ok(uvec2(x, y));
        }
    }

    Err(String::from("invalid format, expected <WIDTH>x<HEIGHT>"))
}

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Cli {
    /// Path to a GLTF file to render
    model: String,

    /// Output path for rendered image
    #[arg(short, long, default_value = "image.png")]
    out: String,

    /// Size of rendered image
    #[arg(long, value_parser = parser_uvec2, default_value = "1280x720")]
    size: UVec2,

    /// Number of samples per pixel
    #[arg(short, long, default_value_t = 128)]
    samples: u32,

    /// Maximum number of bounces per pixel
    #[arg(short, long, default_value_t = 8)]
    bounces: u32,

    /// Path to a HDR file to be used as an environment map
    #[arg(short, long)]
    env_map: Option<String>,
}

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
    env_intensity: f32,
    env_rotation: f32,
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

    // Parse CLI

    let cli = Cli::parse();

    // Create pipeline

    let set_layout = gpu.create_set_layout(&[
        DescriptorInfo {
            stages: ShaderStages::RAYGEN,
            type_: DescriptorType::AccelerationStructure,
            count: 1,
        },
        DescriptorInfo {
            stages: ShaderStages::ANY_HIT | ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::StorageBuffer,
            count: 1,
        },
        DescriptorInfo {
            stages: ShaderStages::ANY_HIT | ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::CombinedImageSampler,
            count: 1024,
        },
        DescriptorInfo {
            stages: ShaderStages::MISS,
            type_: DescriptorType::CombinedImageSampler,
            count: 1,
        },
        DescriptorInfo {
            stages: ShaderStages::RAYGEN,
            type_: DescriptorType::StorageImage,
            count: 1,
        },
    ]);

    let (pipeline, shader_binding_table) =
        create_pipeline(&gpu, set_layout.clone(), cli.env_map.is_some());

    // Load environment map

    let (_, env_image_view) = match &cli.env_map {
        Some(path) => {
            let env_bytes = read(path).unwrap();
            let mut env_decoder = HdrDecoder::new(env_bytes);

            let env_pixels: Vec<f32> = env_decoder
                .decode()
                .unwrap()
                .iter()
                .array_chunks::<3>()
                .flat_map(move |[r, g, b]| [*r, *g, *b, 1.0])
                .collect();

            let env_size = env_decoder
                .get_dimensions()
                .map(move |(width, height)| uvec2(width as u32, height as u32))
                .unwrap();

            gpu.create_filled_image(
                env_size,
                Format::R32G32B32A32_SFLOAT,
                ImageUsage::SAMPLED,
                bytemuck::cast_slice(&env_pixels),
            )
        }
        None => gpu.create_filled_image(
            uvec2(1, 1),
            Format::R32G32B32A32_SFLOAT,
            ImageUsage::SAMPLED,
            bytemuck::cast_slice(&[1.0, 1.0, 1.0, 1.0]),
        ),
    };

    let env_sampler = Sampler::new(
        gpu.device.clone(),
        SamplerCreateInfo::simple_repeat_linear_no_mipmap(),
    )
    .unwrap();

    // Load scene

    let mut scene_builder = SceneBuilder::new(&gpu);

    let camera_data = load_model(&mut scene_builder, &cli.model, Mat4::IDENTITY);

    let scene = scene_builder.build();

    scene.print_stats();
    println!();

    // Create set

    let (image, image_view) = gpu.create_image(
        cli.size,
        Format::R32G32B32A32_SFLOAT,
        ImageUsage::STORAGE | ImageUsage::TRANSFER_SRC | ImageUsage::TRANSFER_DST,
    );

    let mut writes = vec![
        WriteDescriptorSet::acceleration_structure(0, scene.accel_struct.clone()),
        WriteDescriptorSet::buffer(1, scene.instance_buffer.clone()),
        WriteDescriptorSet::image_view_with_layout_sampler(
            3,
            DescriptorImageViewInfo {
                image_view: env_image_view.clone(),
                image_layout: ImageLayout::ShaderReadOnlyOptimal,
            },
            env_sampler.clone(),
        ),
        WriteDescriptorSet::image_view_with_layout(
            4,
            DescriptorImageViewInfo {
                image_view: image_view.clone(),
                image_layout: ImageLayout::General,
            },
        ),
    ];

    if !scene.textures.is_empty() {
        writes.push(WriteDescriptorSet::image_view_with_layout_sampler_array(
            2,
            0,
            scene.textures.iter().map(move |(view, sampler)| {
                (
                    DescriptorImageViewInfo {
                        image_view: view.clone(),
                        image_layout: ImageLayout::ShaderReadOnlyOptimal,
                    },
                    sampler.clone(),
                )
            }),
        ));
    }

    let set =
        DescriptorSet::new(gpu.set_allocator.clone(), set_layout.clone(), writes, []).unwrap();

    // Render

    let mut pc = PushConstants {
        camera: Camera::new(
            camera_data.unwrap_or(CameraData {
                position: vec3(5.0, 2.0, 5.0),
                look_at: Vec3::ZERO,
                fov: 70.0,
            }),
            cli.size.x as f32 / cli.size.y as f32,
        ),
        width: cli.size.x,
        height: cli.size.y,
        bounces: cli.bounces,
        sample: 0,
        env_intensity: 1.0,
        env_rotation: 0.0,
    };

    let start = Instant::now();
    let mut average_duration = Duration::ZERO;

    for _ in tqdm!(0..cli.samples) {
        let (_, duration) = gpu.execute(|commands| {
            if pc.sample == 0 {
                commands
                    .clear_color_image(ClearColorImageInfo::image(image.clone()))
                    .unwrap();
            }

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
                    .trace_rays(
                        shader_binding_table.addresses().clone(),
                        [cli.size.x, cli.size.y, 1],
                    )
                    .unwrap();
            }
        });

        average_duration += duration / cli.samples;

        pc.sample += 1;
    }

    let total = Instant::now() - start;

    println!();
    println!();

    println!("Total:  {:?}", total);
    println!("Sample: {:?}", average_duration);

    // Copy image to buffer

    let image_buffer: Subbuffer<[Vec4]> = gpu.create_buffer(
        BufferUsage::TRANSFER_DST,
        MemoryTypeFilter::HOST_RANDOM_ACCESS,
        (cli.size.x * cli.size.y) as DeviceSize,
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

    let pixels: Vec<U8Vec3> = image_buffer
        .read()
        .unwrap()
        .iter()
        .map(map_color::<color::AgX>)
        .collect();

    // Write pixels to image

    let file = File::create(&cli.out).unwrap();
    let writer = BufWriter::new(file);

    let mut encoder = png::Encoder::new(writer, cli.size.x, cli.size.y);
    encoder.set_color(ColorType::Rgb);
    encoder.set_depth(BitDepth::Eight);

    encoder
        .write_header()
        .unwrap()
        .write_image_data(bytemuck::cast_slice(&pixels))
        .unwrap();
}

fn map_color<TMO: ToneMappingOperator>(color: &Vec4) -> U8Vec3 {
    let mut color = Vec3::new(color.x, color.y, color.z).max(Vec3::ZERO);
    color = TMO::map(color);

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
    env_map: bool,
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
                stages: ShaderStages::RAYGEN | ShaderStages::MISS,
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
                PipelineShaderStageCreateInfo::new(
                    module
                        .entry_point(if env_map { "MissEnvMap" } else { "MissGeneric" })
                        .unwrap()
                ),
                PipelineShaderStageCreateInfo::new(module.entry_point("AnyHit").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("ClosestHit").unwrap()),
            ],
            groups: smallvec![
                RayTracingShaderGroupCreateInfo::General { general_shader: 0 },
                RayTracingShaderGroupCreateInfo::General { general_shader: 1 },
                RayTracingShaderGroupCreateInfo::TrianglesHit {
                    closest_hit_shader: Some(3),
                    any_hit_shader: None,
                },
                RayTracingShaderGroupCreateInfo::TrianglesHit {
                    closest_hit_shader: Some(3),
                    any_hit_shader: Some(2),
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
