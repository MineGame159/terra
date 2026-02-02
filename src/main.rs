#![feature(iter_array_chunks)]

mod color;
mod gpu;
mod model;
mod pt;
mod world;

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use clap::Parser;
use glam::{U8Vec3, UVec2, Vec3, Vec4, uvec2};
use hecs::World;
use image::ColorType;
use kdam::tqdm;
use vulkano::{
    DeviceSize,
    buffer::{BufferUsage, Subbuffer},
    command_buffer::CopyImageToBufferInfo,
    format::Format,
    image::{Image, ImageUsage},
    memory::allocator::MemoryTypeFilter,
};

use crate::{color::ToneMappingOperator, gpu::Gpu, world::Camera};

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

fn main() {
    // Create gpu

    let gpu = Gpu::new();

    // Parse CLI

    let cli = Cli::parse();

    // Create renderer and load model

    let mut renderer = pt::Renderer::new(&gpu);

    {
        let mut world = World::new();

        model::load(&cli.model, &gpu, &mut world).unwrap();

        if let Some(path) = cli.env_map {
            if let Some(camera) = world.query_mut::<&mut Camera>().into_iter().next() {
                camera.env_map_path = path.clone();
            }
        }

        renderer.update(&mut world);
    }

    print_stats(renderer.stats());

    // Create image

    let (image, image_view) = gpu.create_image(
        cli.size,
        Format::R32G32B32A32_SFLOAT,
        ImageUsage::STORAGE | ImageUsage::TRANSFER_SRC | ImageUsage::TRANSFER_DST,
    );

    // Render

    let mut sample = 0u32;

    let start = Instant::now();
    let mut average_duration = Duration::ZERO;

    println!();

    for _ in tqdm!(0..cli.samples) {
        let duration = renderer.render(&image_view, cli.bounces, &mut sample);

        average_duration += duration / cli.samples;
    }

    let total = Instant::now() - start;

    println!();
    println!();

    println!("Total:  {:?}", total);
    println!("Sample: {:?}", average_duration);

    // Write image

    let pixels = read_image(&gpu, image);
    write_image(&cli.out, cli.size, &pixels);
}

#[profiling::function]
fn read_image(gpu: &Gpu, image: Arc<Image>) -> Vec<U8Vec3> {
    let image_buffer: Subbuffer<[Vec4]> = gpu.create_buffer(
        BufferUsage::TRANSFER_DST,
        MemoryTypeFilter::HOST_RANDOM_ACCESS,
        (image.extent()[0] * image.extent()[1]) as DeviceSize,
    );

    gpu.execute(|commands| {
        commands
            .copy_image_to_buffer(CopyImageToBufferInfo::image_buffer(
                image,
                image_buffer.clone(),
            ))
            .unwrap();
    });

    // Read image buffer

    image_buffer
        .read()
        .unwrap()
        .iter()
        .map(map_color::<color::AgX>)
        .collect()
}

#[profiling::function]
fn write_image(path: &str, size: UVec2, pixels: &[U8Vec3]) {
    image::save_buffer(
        path,
        bytemuck::cast_slice(pixels),
        size.x,
        size.y,
        ColorType::Rgb8,
    )
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

fn print_stats(stats: pt::Stats) {
    println!("Meshes: {} ({})", stats.mesh_count, stats.meshes_size);

    println!(
        "Instances: {} ({})",
        stats.instance_count, stats.instances_size
    );

    println!(
        "Materials: {} ({})",
        stats.material_count, stats.materials_size
    );

    println!("Images: {} ({})", stats.image_count, stats.images_size);
}
