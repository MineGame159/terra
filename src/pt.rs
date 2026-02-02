use std::{collections::HashSet, f32, fs, sync::Arc, time::Duration};

use bytesize::ByteSize;
use glam::{UVec2, Vec2, Vec3, Vec3A, Vec4, Vec4Swizzles, uvec2, vec3};
use hecs::World;
use smallvec::smallvec;
use vulkano::{
    DeviceAddress, Packed24_8,
    acceleration_structure::{
        AccelerationStructure, AccelerationStructureGeometries,
        AccelerationStructureGeometryInstancesData, AccelerationStructureGeometryInstancesDataType,
        AccelerationStructureGeometryTrianglesData, AccelerationStructureInstance, GeometryFlags,
    },
    buffer::{BufferContents, BufferUsage, IndexBuffer, Subbuffer},
    command_buffer::ClearColorImageInfo,
    descriptor_set::{
        DescriptorBindingResources, DescriptorImageViewInfo, DescriptorSet, WriteDescriptorSet,
        layout::{DescriptorSetLayout, DescriptorType},
    },
    format::Format,
    image::{
        ImageLayout, ImageUsage,
        sampler::{Sampler, SamplerCreateInfo},
        view::ImageView,
    },
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
    gpu::{DescriptorInfo, Gpu, get_descriptor_size},
    world::{
        Camera, DirectionalLight, EllipseLight, MeshInstance, Node, PointLight, RectangleLight,
        SpotLight, Texture, Vertex,
    },
};

#[derive(Copy, Clone)]
struct CameraInfo {
    position: Vec3,
    look_at: Vec3,
    fov: f32,
}

impl Default for CameraInfo {
    fn default() -> Self {
        Self {
            position: vec3(5.0, 2.0, 5.0),
            look_at: Vec3::ZERO,
            fov: 70.0,
        }
    }
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct CameraData {
    origin: Vec3A,
    lower_left_corner: Vec3A,
    horizontal: Vec3A,
    vertical: Vec3A,
}

impl CameraData {
    fn new(info: CameraInfo, aspect_ratio: f32) -> CameraData {
        let theta = info.fov.to_radians();
        let h = (theta / 2.0).tan();
        let viewport_height = 2.0 * h;
        let viewport_width = aspect_ratio * viewport_height;

        let w = (info.position - info.look_at).normalize();
        let u = Vec3::Y.cross(w).normalize();
        let v = w.cross(u);

        CameraData {
            origin: info.position.into(),
            horizontal: (viewport_width * u).into(),
            vertical: (viewport_height * v).into(),
            lower_left_corner: (info.position
                - (viewport_width * u) / 2.0
                - (viewport_height * v) / 2.0
                - w)
                .into(),
        }
    }
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct PushConstants {
    camera: CameraData,
    width: u32,
    height: u32,
    bounces: u32,
    sample: u32,
    miss_index: u32,
    env_intensity: f32,
    env_rotation: f32,
}

struct Mesh {
    accel_struct: Arc<AccelerationStructure>,
    indices: Subbuffer<[u32]>,
    vertices: Subbuffer<[Vertex]>,
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct Material {
    albedo_factor: Vec4,
    albedo_texture: u32,

    metallic_factor: f32,
    roughness_factor: f32,
    metallic_roughness_texture: u32,

    emissive_factor: Vec3A,
    emissive_texture: u32,

    ior: f32,

    specular_factor: f32,
    specular_texture: u32,

    specular_color_factor: Vec3A,
    specular_color_texture: u32,

    clearcoat_factor: f32,
    clearcoat_texture: u32,

    clearcoat_roughness_factor: f32,
    clearcoat_roughness_texture: u32,

    normal_texture: u32,
    normal_scale: f32,

    _pad2: u32,
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct Instance {
    indices: DeviceAddress,
    vertices: DeviceAddress,

    material: DeviceAddress,
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
struct Light {
    type_: u32,
    range: f32,
    inner_cone_cos: f32,
    outer_cone_cos: f32,

    position: Vec3A,
    color: Vec3A,
    direction: Vec3A,

    size: Vec2,

    _pad: Vec2,
}

#[derive(Copy, Clone)]
pub struct Stats {
    pub mesh_count: usize,
    pub meshes_size: ByteSize,

    pub instance_count: usize,
    pub instances_size: ByteSize,

    pub material_count: usize,
    pub materials_size: ByteSize,

    pub image_count: usize,
    pub images_size: ByteSize,
}

pub struct Renderer<'a> {
    gpu: &'a Gpu,

    scene_set_layout: Arc<DescriptorSetLayout>,
    output_set_layout: Arc<DescriptorSetLayout>,
    env_map_set_layout: Arc<DescriptorSetLayout>,

    pipeline: Arc<RayTracingPipeline>,
    sbt: ShaderBindingTable,

    meshes: Vec<Mesh>,
    material_buffer: Option<Subbuffer<[Material]>>,
    accel_struct: Option<Arc<AccelerationStructure>>,

    scene_set: Option<Arc<DescriptorSet>>,
    env_map_set: Option<Arc<DescriptorSet>>,
    output_set: Option<Arc<DescriptorSet>>,

    camera_info: CameraInfo,
    has_env_map: bool,
}

#[profiling::all_functions]
impl<'a> Renderer<'a> {
    pub fn new(gpu: &'a Gpu) -> Renderer<'a> {
        let scene_set_layout = create_scene_set_layout(gpu);
        let env_map_set_layout = create_env_map_set_layout(gpu);
        let output_set_layout = create_output_set_layout(gpu);

        let pipeline = create_pipeline(
            gpu,
            vec![
                scene_set_layout.clone(),
                env_map_set_layout.clone(),
                output_set_layout.clone(),
            ],
        );

        let sbt = ShaderBindingTable::new(gpu.memory_allocator.clone(), &pipeline).unwrap();

        Renderer {
            gpu,

            scene_set_layout,
            output_set_layout,
            env_map_set_layout,

            pipeline,
            sbt,

            meshes: vec![],
            material_buffer: None,
            accel_struct: None,

            scene_set: None,
            output_set: None,
            env_map_set: None,

            camera_info: Default::default(),
            has_env_map: false,
        }
    }

    pub fn update(&mut self, world: &mut World) {
        fn texture(
            textures: &mut Vec<(DescriptorImageViewInfo, Arc<Sampler>)>,
            texture: &Texture,
        ) -> u32 {
            match texture {
                Some((view, sampler)) => {
                    textures
                        .iter()
                        .position(|(info, sampler2)| {
                            &info.image_view == view && sampler2 == sampler
                        })
                        .unwrap_or_else(move || {
                            textures.push((
                                DescriptorImageViewInfo {
                                    image_view: view.clone(),
                                    image_layout: ImageLayout::ShaderReadOnlyOptimal,
                                },
                                sampler.clone(),
                            ));
                            textures.len() - 1
                        }) as u32
                        + 1
                }
                None => 0,
            }
        }

        self.meshes.clear();
        self.material_buffer = None;
        self.accel_struct = None;
        self.scene_set = None;
        self.env_map_set = None;
        self.camera_info = Default::default();

        let mut textures = Vec::with_capacity(8);
        let mut materials = Vec::with_capacity(8);
        let mut instances = Vec::with_capacity(8);
        let mut accel_struct_instances = Vec::with_capacity(8);

        // Create bottom level acceleration structures

        for (node, instance) in world.query_mut::<(&Node, &MeshInstance)>() {
            let (accel_struct, _) = self.gpu.execute(|commands| {
                self.gpu.create_accel_struct(
                    true,
                    AccelerationStructureGeometries::Triangles(vec![
                        AccelerationStructureGeometryTrianglesData {
                            flags: GeometryFlags::empty(),
                            vertex_data: Some(instance.mesh.positions.clone().into_bytes()),
                            vertex_stride: size_of::<Vec3>() as u32,
                            max_vertex: (instance.mesh.positions.len() - 1) as u32,
                            index_data: Some(IndexBuffer::U32(instance.mesh.indices.clone())),
                            transform_data: None,
                            ..AccelerationStructureGeometryTrianglesData::new(
                                Format::R32G32B32_SFLOAT,
                            )
                        },
                    ]),
                    commands,
                )
            });

            self.meshes.push(Mesh {
                accel_struct: accel_struct.clone(),
                indices: instance.mesh.indices.clone(),
                vertices: instance.mesh.vertices.clone(),
            });

            materials.push({
                let m = &instance.material;
                Material {
                    albedo_factor: m.albedo_factor,
                    albedo_texture: texture(&mut textures, &m.albedo_texture),
                    metallic_factor: m.metallic_factor,
                    roughness_factor: m.roughness_factor,
                    metallic_roughness_texture: texture(
                        &mut textures,
                        &m.metallic_roughness_texture,
                    ),
                    emissive_factor: m.emissive_factor.into(),
                    emissive_texture: texture(&mut textures, &m.emissive_texture),
                    ior: m.ior,
                    specular_factor: m.specular_factor,
                    specular_texture: texture(&mut textures, &m.specular_texture),
                    specular_color_factor: m.specular_color_factor.into(),
                    specular_color_texture: texture(&mut textures, &m.specular_color_texture),
                    clearcoat_factor: m.clearcoat_factor,
                    clearcoat_texture: texture(&mut textures, &m.clearcoat_texture),
                    clearcoat_roughness_factor: m.clearcoat_roughness_factor,
                    clearcoat_roughness_texture: texture(
                        &mut textures,
                        &m.clearcoat_roughness_texture,
                    ),
                    normal_texture: texture(&mut textures, &m.normal_texture),
                    normal_scale: m.normal_scale,
                    _pad2: 0,
                }
            });

            let material_index = materials.len() - 1;

            instances.push(Instance {
                indices: instance.mesh.indices.device_address().unwrap().into(),
                vertices: instance.mesh.vertices.device_address().unwrap().into(),
                material: material_index as u64,
            });

            let transform = node.transform();

            accel_struct_instances.push(AccelerationStructureInstance {
                transform: [
                    transform.row(0).to_array(),
                    transform.row(1).to_array(),
                    transform.row(2).to_array(),
                ],
                instance_custom_index_and_mask: Packed24_8::new(instances.len() as u32 - 1, 0xFF),
                instance_shader_binding_table_record_offset_and_flags: Packed24_8::new(
                    if instance.material.opaque == 1 { 0 } else { 1 },
                    0,
                ),
                acceleration_structure_reference: accel_struct.device_address().into(),
            });
        }

        // Create material buffer and fix material addresses

        let material_buffer = self
            .gpu
            .create_filled_buffer(BufferUsage::SHADER_DEVICE_ADDRESS, &materials);

        for instance in &mut instances {
            instance.material = material_buffer
                .clone()
                .index(instance.material)
                .device_address()
                .unwrap()
                .into();
        }

        self.material_buffer = Some(material_buffer);

        // Create instance buffer

        let instance_buffer = self
            .gpu
            .create_filled_buffer(BufferUsage::STORAGE_BUFFER, &instances);

        // Create top level acceleration structure

        let accel_struct_instance_buffer = self.gpu.create_filled_buffer(
            BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                | BufferUsage::SHADER_DEVICE_ADDRESS,
            &accel_struct_instances,
        );

        let (accel_struct, _) = self.gpu.execute(|commands| {
            self.gpu.create_accel_struct(
                false,
                AccelerationStructureGeometries::Instances(
                    AccelerationStructureGeometryInstancesData::new(
                        AccelerationStructureGeometryInstancesDataType::Values(Some(
                            accel_struct_instance_buffer,
                        )),
                    ),
                ),
                commands,
            )
        });

        self.accel_struct = Some(accel_struct.clone());

        // Find lights

        let mut lights = Vec::with_capacity(8);

        for (node, light) in world.query_mut::<(&Node, &PointLight)>() {
            lights.push(Light {
                range: light.range,
                ..base_light(0, node, light.color)
            });
        }

        for (node, light) in world.query_mut::<(&Node, &SpotLight)>() {
            lights.push(Light {
                range: light.range,
                inner_cone_cos: light.inner_cone_angle.cos(),
                outer_cone_cos: light.outer_cone_angle.cos(),
                ..base_light(1, node, light.color)
            });
        }

        for (node, light) in world.query_mut::<(&Node, &DirectionalLight)>() {
            lights.push(base_light(2, node, light.color));
        }

        for (node, light) in world.query_mut::<(&Node, &RectangleLight)>() {
            lights.push(Light {
                size: light.size,
                ..base_light(3, node, light.color)
            });
        }

        for (node, light) in world.query_mut::<(&Node, &EllipseLight)>() {
            lights.push(Light {
                size: light.size,
                ..base_light(4, node, light.color)
            });
        }

        // Create scene descriptor set

        let mut writes = vec![
            WriteDescriptorSet::acceleration_structure(0, accel_struct),
            WriteDescriptorSet::buffer(1, instance_buffer.clone()),
        ];

        if !textures.is_empty() {
            writes.push(WriteDescriptorSet::image_view_with_layout_sampler_array(
                2, 0, textures,
            ));
        }

        if !lights.is_empty() {
            let light_buffer = self
                .gpu
                .create_filled_buffer(BufferUsage::STORAGE_BUFFER, &lights);

            writes.push(WriteDescriptorSet::buffer(3, light_buffer));
        }

        self.scene_set = Some(
            DescriptorSet::new(
                self.gpu.set_allocator.clone(),
                self.scene_set_layout.clone(),
                writes,
                [],
            )
            .unwrap(),
        );

        // Find camera

        if let Some((node, camera)) = world.query_mut::<(&Node, &Camera)>().into_iter().next() {
            if !camera.env_map_path.is_empty() {
                self.setup_env_map_set(&camera.env_map_path);
            }

            self.camera_info = CameraInfo {
                position: node.position,
                look_at: node.position + node.transform().transform_vector3(Vec3::NEG_Z),
                fov: camera.fov,
            };
        }

        if self.env_map_set.is_none() {
            self.setup_dummy_env_map_set();
        }
    }

    pub fn stats(&self) -> Stats {
        let images = self.scene_set.as_ref().map_or(HashSet::new(), move |set| {
            match set.resources().binding(2).unwrap() {
                DescriptorBindingResources::ImageViewSampler(elements) => elements
                    .iter()
                    .flatten()
                    .map(move |(info, _)| info.image_view.clone())
                    .collect(),
                _ => HashSet::new(),
            }
        });

        Stats {
            mesh_count: self.meshes.len(),
            meshes_size: ByteSize::b(
                self.meshes
                    .iter()
                    .map(move |mesh| {
                        mesh.accel_struct.buffer().size()
                            + mesh.indices.size()
                            + mesh.vertices.size()
                    })
                    .sum(),
            ),

            instance_count: self.scene_set.as_ref().map_or(0, move |set| {
                match set.resources().binding(1).unwrap() {
                    DescriptorBindingResources::Buffer(elements) => elements[0]
                        .as_ref()
                        .unwrap()
                        .buffer
                        .clone()
                        .slice(elements[0].as_ref().unwrap().range.clone())
                        .reinterpret_ref::<[Instance]>()
                        .len()
                        as usize,
                    DescriptorBindingResources::BufferView(elements) => elements[0]
                        .as_ref()
                        .unwrap()
                        .buffer()
                        .reinterpret_ref::<[Instance]>()
                        .len()
                        as usize,
                    _ => 0,
                }
            }),
            instances_size: ByteSize::b(self.scene_set.as_ref().map_or(0, move |set| {
                get_descriptor_size(set.resources().binding(1).unwrap())
            })),

            material_count: self
                .material_buffer
                .as_ref()
                .map_or(0, move |buffer| buffer.len() as usize),
            materials_size: ByteSize::b(
                self.material_buffer
                    .as_ref()
                    .map_or(0, move |buffer| buffer.size()),
            ),

            image_count: images.len(),
            images_size: ByteSize::b(
                images
                    .iter()
                    .map(move |view| {
                        view.image()
                            .extent()
                            .iter()
                            .map(move |v| *v as u64)
                            .product::<u64>()
                            * view.format().block_size()
                    })
                    .sum(),
            ),
        }
    }

    pub fn render(&mut self, view: &Arc<ImageView>, bounces: u32, sample: &mut u32) -> Duration {
        // Setup output set

        let width = view.image().extent()[0];
        let height = view.image().extent()[1];

        self.setup_output_set(view.clone());

        // Setup push constants

        let pc = PushConstants {
            camera: CameraData::new(self.camera_info, width as f32 / height as f32),
            width: width,
            height: height,
            bounces: bounces,
            sample: *sample,
            miss_index: if self.has_env_map { 1 } else { 0 },
            env_intensity: 1.0,
            env_rotation: 0.0,
        };

        *sample += 1;

        // Execute

        self.gpu
            .execute(move |commands| {
                if pc.sample == 0 {
                    commands
                        .clear_color_image(ClearColorImageInfo::image(view.image().clone()))
                        .unwrap();
                }

                commands
                    .bind_pipeline_ray_tracing(self.pipeline.clone())
                    .unwrap();

                commands
                    .bind_descriptor_sets(
                        PipelineBindPoint::RayTracing,
                        self.pipeline.layout().clone(),
                        0,
                        (
                            self.scene_set.as_ref().unwrap().clone(),
                            self.env_map_set.as_ref().unwrap().clone(),
                            self.output_set.as_ref().unwrap().clone(),
                        ),
                    )
                    .unwrap();

                commands
                    .push_constants(self.pipeline.layout().clone(), 0, pc)
                    .unwrap();

                unsafe {
                    commands
                        .trace_rays(self.sbt.addresses().clone(), [width, height, 1])
                        .unwrap();
                }
            })
            .1
    }

    fn setup_env_map_set(&mut self, path: &str) {
        // Read image

        let env_bytes = {
            profiling::scope!("fs::read");
            fs::read(path).unwrap()
        };

        let mut env_decoder = {
            profiling::scope!("HdrDecoder::new");
            HdrDecoder::new(env_bytes)
        };

        let env_pixels: Vec<f32> = {
            profiling::scope!("HdrDecoder::decode");
            env_decoder
                .decode()
                .unwrap()
                .iter()
                .array_chunks::<3>()
                .flat_map(move |[r, g, b]| [*r, *g, *b, 1.0])
                .collect()
        };

        let env_size = env_decoder
            .get_dimensions()
            .map(move |(width, height)| uvec2(width as u32, height as u32))
            .unwrap();

        // Create image and sampler

        let (_, view) = self.gpu.create_filled_image(
            env_size,
            Format::R32G32B32A32_SFLOAT,
            ImageUsage::SAMPLED,
            bytemuck::cast_slice(&env_pixels),
        );

        let sampler = Sampler::new(
            self.gpu.device.clone(),
            SamplerCreateInfo::simple_repeat_linear_no_mipmap(),
        )
        .unwrap();

        // Create CDF buffers

        let (conditional_buffer, marginal_buffer) =
            self.create_env_map_cdf_buffers(env_size, bytemuck::cast_slice(&env_pixels));

        // Create set

        self.env_map_set = Some(
            DescriptorSet::new(
                self.gpu.set_allocator.clone(),
                self.env_map_set_layout.clone(),
                [
                    WriteDescriptorSet::image_view_with_layout_sampler(
                        0,
                        DescriptorImageViewInfo {
                            image_view: view.clone(),
                            image_layout: ImageLayout::ShaderReadOnlyOptimal,
                        },
                        sampler.clone(),
                    ),
                    WriteDescriptorSet::buffer(1, marginal_buffer),
                    WriteDescriptorSet::buffer(2, conditional_buffer),
                ],
                None,
            )
            .unwrap(),
        );

        self.has_env_map = true;
    }

    fn setup_dummy_env_map_set(&mut self) {
        // Create image and sampler

        let (_, view) = self.gpu.create_filled_image(
            uvec2(1, 1),
            Format::R32G32B32A32_SFLOAT,
            ImageUsage::SAMPLED,
            bytemuck::cast_slice(&[1.0, 1.0, 1.0, 1.0]),
        );

        let sampler = Sampler::new(
            self.gpu.device.clone(),
            SamplerCreateInfo::simple_repeat_linear_no_mipmap(),
        )
        .unwrap();

        // Create CDF buffers

        let (conditional_buffer, marginal_buffer) =
            self.create_env_map_cdf_buffers(uvec2(1, 1), &[Vec4::ONE]);

        // Create set

        self.env_map_set = Some(
            DescriptorSet::new(
                self.gpu.set_allocator.clone(),
                self.env_map_set_layout.clone(),
                [
                    WriteDescriptorSet::image_view_with_layout_sampler(
                        0,
                        DescriptorImageViewInfo {
                            image_view: view.clone(),
                            image_layout: ImageLayout::ShaderReadOnlyOptimal,
                        },
                        sampler.clone(),
                    ),
                    WriteDescriptorSet::buffer(1, marginal_buffer),
                    WriteDescriptorSet::buffer(2, conditional_buffer),
                ],
                None,
            )
            .unwrap(),
        );

        self.has_env_map = false;
    }

    fn create_env_map_cdf_buffers(
        &self,
        size: UVec2,
        pixels: &[Vec4],
    ) -> (Subbuffer<[f32]>, Subbuffer<[f32]>) {
        macro_rules! index {
            ($x:expr, $y:expr) => {
                ($y * size.x + $x) as usize
            };
        }

        let mut conditional = vec![0.0; (size.x * size.y) as usize];
        let mut marginal = vec![0.0; size.y as usize];

        // Calculate weight for each pixel

        for y in 0..size.y {
            let v = (y as f32 + 0.5) / size.y as f32;
            let sin_theta = (v * f32::consts::PI).sin();

            for x in 0..size.x {
                let i = index!(x, y);

                let luminance = pixels[i].xyz().dot(vec3(0.2126, 0.7152, 0.0722));
                conditional[i] = luminance * sin_theta;
            }
        }

        // Prefix sum and accumulate rows

        for y in 0..size.y {
            let mut sum = 0.0;

            for x in 0..size.x {
                let i = index!(x, y);

                sum += conditional[i];
                conditional[i] = sum;
            }

            if sum > 1e-6 {
                for x in 0..size.x {
                    conditional[index!(x, y)] /= sum;
                }
            } else {
                for x in 0..size.x {
                    conditional[index!(x, y)] = (x as f32 + 1.0) / size.x as f32;
                }
            }

            marginal[y as usize] = sum;
        }

        // Accumulate marginal

        let mut total_sum = 0.0;

        for y in 0..size.y {
            total_sum += marginal[y as usize];
            marginal[y as usize] = total_sum;
        }

        if total_sum > 1e-6 {
            for y in 0..size.y {
                marginal[y as usize] /= total_sum;
            }
        } else {
            for y in 0..size.y {
                marginal[y as usize] = (y as f32 + 1.0) / size.y as f32;
            }
        }

        // Create buffers

        let conditional_buffer = self
            .gpu
            .create_filled_buffer(BufferUsage::STORAGE_BUFFER, &conditional);

        let marginal_buffer = self
            .gpu
            .create_filled_buffer(BufferUsage::STORAGE_BUFFER, &marginal);

        (conditional_buffer, marginal_buffer)
    }

    fn setup_output_set(&mut self, view: Arc<ImageView>) {
        if let Some(set) = self.output_set.as_ref() {
            match set.clone().resources().binding(0).unwrap() {
                DescriptorBindingResources::ImageView(infos)
                    if infos[0].as_ref().unwrap().image_view != view =>
                {
                    self.output_set = None
                }
                _ => self.output_set = None,
            }
        }

        if self.output_set.is_none() {
            self.output_set = Some(
                DescriptorSet::new(
                    self.gpu.set_allocator.clone(),
                    self.output_set_layout.clone(),
                    [WriteDescriptorSet::image_view_with_layout(
                        0,
                        DescriptorImageViewInfo {
                            image_view: view,
                            image_layout: ImageLayout::General,
                        },
                    )],
                    None,
                )
                .unwrap(),
            );
        }
    }
}

fn base_light(type_: u32, node: &Node, color: Vec3) -> Light {
    Light {
        type_,
        range: 0.0,
        inner_cone_cos: 0.0,
        outer_cone_cos: 0.0,
        position: node.position.into(),
        color: color.into(),
        direction: node.transform().transform_vector3(Vec3::NEG_Z).into(),
        size: Vec2::ZERO,
        _pad: Vec2::ZERO,
    }
}

#[profiling::function]
fn create_scene_set_layout(gpu: &Gpu) -> Arc<DescriptorSetLayout> {
    gpu.create_set_layout(&[
        DescriptorInfo {
            stages: ShaderStages::RAYGEN | ShaderStages::CLOSEST_HIT,
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
            stages: ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::StorageBuffer,
            count: 1,
        },
    ])
}

#[profiling::function]
fn create_env_map_set_layout(gpu: &Gpu) -> Arc<DescriptorSetLayout> {
    gpu.create_set_layout(&[
        DescriptorInfo {
            stages: ShaderStages::MISS | ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::CombinedImageSampler,
            count: 1,
        },
        DescriptorInfo {
            stages: ShaderStages::MISS | ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::StorageBuffer,
            count: 1,
        },
        DescriptorInfo {
            stages: ShaderStages::MISS | ShaderStages::CLOSEST_HIT,
            type_: DescriptorType::StorageBuffer,
            count: 1,
        },
    ])
}

#[profiling::function]
fn create_output_set_layout(gpu: &Gpu) -> Arc<DescriptorSetLayout> {
    gpu.create_set_layout(&[DescriptorInfo {
        stages: ShaderStages::RAYGEN,
        type_: DescriptorType::StorageImage,
        count: 1,
    }])
}

#[profiling::function]
fn create_pipeline(
    gpu: &Gpu,
    set_layouts: Vec<Arc<DescriptorSetLayout>>,
) -> Arc<RayTracingPipeline> {
    const SPV_RAY: &'static [u8] = include_bytes!(concat!(env!("OUT_DIR"), "/shaders/ray.spv"));

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
            set_layouts,
            push_constant_ranges: vec![PushConstantRange {
                stages: ShaderStages::RAYGEN | ShaderStages::CLOSEST_HIT | ShaderStages::MISS,
                offset: 0,
                size: size_of::<PushConstants>() as u32,
            }],
            ..Default::default()
        },
    )
    .unwrap();

    RayTracingPipeline::new(
        gpu.device.clone(),
        None,
        RayTracingPipelineCreateInfo {
            stages: smallvec![
                PipelineShaderStageCreateInfo::new(module.entry_point("RayGen").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("MissGeneric").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("MissEnvMap").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("MissShadow").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("AnyHit").unwrap()),
                PipelineShaderStageCreateInfo::new(module.entry_point("ClosestHit").unwrap()),
            ],
            groups: smallvec![
                RayTracingShaderGroupCreateInfo::General { general_shader: 0 }, // RayGen
                RayTracingShaderGroupCreateInfo::General { general_shader: 1 }, // MissGeneric
                RayTracingShaderGroupCreateInfo::General { general_shader: 2 }, // MissEnvMap
                RayTracingShaderGroupCreateInfo::General { general_shader: 3 }, // MissShadow
                RayTracingShaderGroupCreateInfo::TrianglesHit {
                    closest_hit_shader: Some(5), // ClosestHit
                    any_hit_shader: None,
                },
                RayTracingShaderGroupCreateInfo::TrianglesHit {
                    closest_hit_shader: Some(5), // ClosestHit
                    any_hit_shader: Some(4),     // AnyHit
                },
            ],
            max_pipeline_ray_recursion_depth: 2,
            ..RayTracingPipelineCreateInfo::layout(layout.clone())
        },
    )
    .unwrap()
}
