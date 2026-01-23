use std::{borrow::Cow, sync::Arc};

use bytesize::ByteSize;
use glam::{Mat4, UVec2, Vec3, Vec4, vec4};
use vulkano::{
    DeviceAddress, Packed24_8,
    acceleration_structure::{
        AccelerationStructure, AccelerationStructureGeometries,
        AccelerationStructureGeometryInstancesData, AccelerationStructureGeometryInstancesDataType,
        AccelerationStructureGeometryTrianglesData, AccelerationStructureInstance, GeometryFlags,
    },
    buffer::{BufferContents, BufferUsage, IndexBuffer, Subbuffer},
    format::{Format, FormatFeatures},
    image::{
        ImageUsage,
        sampler::{Filter, Sampler, SamplerAddressMode, SamplerCreateInfo, SamplerMipmapMode},
        view::ImageView,
    },
};

use crate::gpu::Gpu;

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
pub struct Vertex {
    pub normal: Vec4,
    pub uv: Vec4,
    pub tangent: Vec4,
}

#[derive(Copy, Clone, Default)]
pub struct CameraData {
    pub position: Vec3,
    pub look_at: Vec3,
    pub fov: f32,
}

pub struct BuiltMesh {
    pub vertex_buffer: Subbuffer<[Vertex]>,
    pub index_buffer: Subbuffer<[u32]>,
}

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
pub struct BuiltInstance {
    pub vertices: DeviceAddress,
    pub indices: DeviceAddress,

    pub material: DeviceAddress,
}

pub struct Scene {
    pub mesh_accel_structs: Vec<Arc<AccelerationStructure>>,
    pub accel_struct: Arc<AccelerationStructure>,

    pub meshes: Vec<BuiltMesh>,
    pub instance_buffer: Subbuffer<[BuiltInstance]>,
    pub materials: Subbuffer<[Material]>,
    pub textures: Vec<(Arc<ImageView>, Arc<Sampler>)>,
}

impl Scene {
    pub fn print_stats(&self) {
        println!(
            "Meshes: {} ({})",
            self.meshes.len(),
            ByteSize::b(
                self.meshes
                    .iter()
                    .map(move |mesh| mesh.vertex_buffer.as_bytes().len()
                        + mesh.index_buffer.as_bytes().len())
                    .sum()
            )
        );

        println!(
            "Instances: {} ({})",
            self.instance_buffer.len(),
            ByteSize::b(self.instance_buffer.as_bytes().len())
        );

        println!(
            "Materials: {} ({})",
            self.materials.len(),
            ByteSize::b(self.materials.as_bytes().len())
        );

        println!(
            "Textures: {} ({})",
            self.textures.len(),
            ByteSize::b(
                self.textures
                    .iter()
                    .map(move |(view, _)| view
                        .image()
                        .extent()
                        .iter()
                        .map(move |v| *v as u64)
                        .product::<u64>()
                        * view.image().format().block_size())
                    .sum()
            )
        );
    }
}

macro_rules! index_id {
    ($name:ident) => {
        #[derive(BufferContents, PartialEq, Copy, Clone, Debug)]
        #[repr(transparent)]
        pub struct $name(u32);

        impl $name {
            fn new(index: u32) -> Self {
                Self { 0: index + 1 }
            }

            pub fn empty() -> Self {
                Self { 0: 0 }
            }

            pub fn valid(self) -> bool {
                self.0 > 0
            }

            pub fn index(self) -> usize {
                assert!(self.0 > 0);
                self.0 as usize - 1
            }
        }
    };
}

index_id!(MeshId);
index_id!(ImageId);
index_id!(TextureId);

#[derive(BufferContents, PartialEq, Copy, Clone)]
#[repr(C)]
pub struct Material {
    pub albedo_factor: Vec4,
    pub albedo_texture: TextureId,

    pub metallic_factor: f32,
    pub roughness_factor: f32,
    pub metallic_roughness_texture: TextureId,

    pub emissive_factor: Vec4,
    pub emissive_texture: TextureId,

    pub ior: f32,

    pub specular_factor: f32,
    pub specular_texture: TextureId,

    pub specular_color_factor: Vec4,
    pub specular_color_texture: TextureId,

    pub clearcoat_factor: f32,
    pub clearcoat_texture: TextureId,

    pub clearcoat_roughness_factor: f32,
    pub clearcoat_roughness_texture: TextureId,

    pub normal_texture: TextureId,

    pub opaque: u32,

    pub _pad2: u32,
}

impl Default for Material {
    fn default() -> Self {
        Self {
            albedo_factor: Vec4::ONE,
            albedo_texture: TextureId::empty(),

            metallic_factor: 0.0,
            roughness_factor: 0.5,
            metallic_roughness_texture: TextureId::empty(),

            emissive_factor: Vec4::ZERO,
            emissive_texture: TextureId::empty(),

            ior: 1.5,

            specular_factor: 1.0,
            specular_texture: TextureId::empty(),

            specular_color_factor: Vec4::ONE,
            specular_color_texture: TextureId::empty(),

            clearcoat_factor: 0.0,
            clearcoat_texture: TextureId::empty(),

            clearcoat_roughness_factor: 0.0,
            clearcoat_roughness_texture: TextureId::empty(),

            normal_texture: TextureId::empty(),

            opaque: 0,

            _pad2: 0,
        }
    }
}

struct Mesh {
    positions: Vec<Vec3>,
    vertices: Vec<Vertex>,
    indices: Vec<u32>,
}

struct Instance {
    mesh_id: MeshId,
    transform: Mat4,
    material: usize,
}

pub struct SceneBuilder<'a> {
    gpu: &'a Gpu,

    meshes: Vec<Mesh>,
    instances: Vec<Instance>,
    materials: Vec<Material>,

    images: Vec<Arc<ImageView>>,
    textures: Vec<(Arc<ImageView>, Arc<Sampler>)>,
}

#[profiling::all_functions]
impl<'a> SceneBuilder<'a> {
    pub fn new(gpu: &'a Gpu) -> SceneBuilder<'a> {
        SceneBuilder {
            gpu,

            meshes: Vec::with_capacity(8),
            instances: Vec::with_capacity(8),
            materials: Vec::with_capacity(8),

            images: Vec::with_capacity(8),
            textures: Vec::with_capacity(8),
        }
    }

    pub fn create_image(&mut self, size: UVec2, format: Format, pixels: &[u8]) -> ImageId {
        assert_eq!(
            size.as_usizevec2().element_product() * format.block_size() as usize,
            pixels.len()
        );

        let (format, pixels) = {
            profiling::scope!("convert format");

            match format.components() {
                [8, 8, 0, 0]
                    if !self
                        .gpu
                        .does_format_support(format, FormatFeatures::SAMPLED_IMAGE) =>
                {
                    (
                        format_2_to_4(format),
                        Cow::Owned(
                            pixels
                                .iter()
                                .array_chunks::<2>()
                                .flat_map(|[r, g]| [*r, *g, *r, *g])
                                .collect(),
                        ),
                    )
                }
                [8, 8, 8, 0]
                    if !self
                        .gpu
                        .does_format_support(format, FormatFeatures::SAMPLED_IMAGE) =>
                {
                    (
                        format_3_to_4(format),
                        Cow::Owned(
                            pixels
                                .iter()
                                .array_chunks::<3>()
                                .flat_map(|[r, g, b]| [*r, *g, *b, 0xFF])
                                .collect(),
                        ),
                    )
                }
                [16, 16, 0, 0]
                    if !self
                        .gpu
                        .does_format_support(format, FormatFeatures::SAMPLED_IMAGE) =>
                {
                    (
                        format_2_to_4(format),
                        Cow::Owned(bytemuck::cast_vec(
                            bytemuck::cast_slice::<u8, u16>(pixels)
                                .iter()
                                .array_chunks::<2>()
                                .flat_map(|[r, g]| [*r, *g, *r, *g])
                                .collect::<Vec<u16>>(),
                        )),
                    )
                }
                [16, 16, 16, 0]
                    if !self
                        .gpu
                        .does_format_support(format, FormatFeatures::SAMPLED_IMAGE) =>
                {
                    (
                        format_3_to_4(format),
                        Cow::Owned(bytemuck::cast_vec(
                            bytemuck::cast_slice::<u8, u16>(pixels)
                                .iter()
                                .array_chunks::<3>()
                                .flat_map(|[r, g, b]| [*r, *g, *b, 0xFFFF])
                                .collect::<Vec<u16>>(),
                        )),
                    )
                }
                [32, 32, 0, 0]
                    if !self
                        .gpu
                        .does_format_support(format, FormatFeatures::SAMPLED_IMAGE) =>
                {
                    (
                        format_2_to_4(format),
                        Cow::Owned(bytemuck::cast_vec(
                            bytemuck::cast_slice::<u8, f32>(pixels)
                                .iter()
                                .array_chunks::<2>()
                                .flat_map(|[r, g]| [*r, *g, *r, *g])
                                .collect::<Vec<f32>>(),
                        )),
                    )
                }
                [32, 32, 32, 0]
                    if !self
                        .gpu
                        .does_format_support(format, FormatFeatures::SAMPLED_IMAGE) =>
                {
                    (
                        format_3_to_4(format),
                        Cow::Owned(bytemuck::cast_vec(
                            bytemuck::cast_slice::<u8, f32>(pixels)
                                .iter()
                                .array_chunks::<3>()
                                .flat_map(|[r, g, b]| [*r, *g, *b, 1.0])
                                .collect::<Vec<f32>>(),
                        )),
                    )
                }
                _ => (format, Cow::Borrowed(pixels)),
            }
        };

        let (_, view) = self
            .gpu
            .create_filled_image(size, format, ImageUsage::SAMPLED, &pixels);

        self.images.push(view);

        ImageId::new(self.images.len() as u32 - 1)
    }

    pub fn create_texture(
        &mut self,
        image_id: ImageId,
        min: Filter,
        mag: Filter,
        wrap_s: SamplerAddressMode,
        wrap_t: SamplerAddressMode,
    ) -> TextureId {
        let view = self.images[image_id.index()].clone();

        let sampler = Sampler::new(
            self.gpu.device.clone(),
            SamplerCreateInfo {
                mag_filter: mag,
                min_filter: min,
                mipmap_mode: SamplerMipmapMode::Nearest,
                address_mode: [wrap_s, wrap_t, SamplerAddressMode::Repeat],
                lod: 0.0..=1.0,
                ..Default::default()
            },
        )
        .unwrap();

        self.textures.push((view, sampler));

        TextureId::new(self.textures.len() as u32 - 1)
    }

    pub fn create_mesh(
        &mut self,
        positions: Vec<Vec3>,
        vertices: Vec<Vertex>,
        indices: Vec<u32>,
    ) -> MeshId {
        assert_eq!(positions.len(), vertices.len());

        self.meshes.push(Mesh {
            positions,
            vertices,
            indices,
        });

        MeshId::new(self.meshes.len() as u32 - 1)
    }

    pub fn add_instance(&mut self, mesh_id: MeshId, transform: Mat4, material: Material) {
        assert_eq!(transform.row(3), vec4(0.0, 0.0, 0.0, 1.0));
        assert!(mesh_id.valid());

        let material_index = self
            .materials
            .iter()
            .position(move |a| *a == material)
            .unwrap_or_else(|| {
                self.materials.push(material);
                self.materials.len() - 1
            });

        self.instances.push(Instance {
            mesh_id,
            transform,
            material: material_index,
        });
    }

    pub fn build(&self) -> Scene {
        // Create material buffer

        let materials = self
            .gpu
            .create_filled_buffer(BufferUsage::SHADER_DEVICE_ADDRESS, &self.materials);

        // Create mesh (bottom level) acceleration structures

        let mut mesh_accel_structs = Vec::with_capacity(self.meshes.len());
        let mut meshes = Vec::with_capacity(self.meshes.len());

        for i in 0..self.meshes.len() {
            let mesh = &self.meshes[i];

            let position_buffer = self.gpu.create_filled_buffer(
                BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                    | BufferUsage::SHADER_DEVICE_ADDRESS,
                &mesh.positions,
            );

            let vertex_buffer = self.gpu.create_filled_buffer(
                BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                    | BufferUsage::SHADER_DEVICE_ADDRESS,
                &mesh.vertices,
            );

            let index_buffer = self.gpu.create_filled_buffer(
                BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                    | BufferUsage::SHADER_DEVICE_ADDRESS,
                &mesh.indices,
            );

            meshes.push(BuiltMesh {
                vertex_buffer,
                index_buffer: index_buffer.clone(),
            });

            self.gpu.execute(|commands| {
                mesh_accel_structs.push(self.gpu.create_accel_struct(
                    true,
                    AccelerationStructureGeometries::Triangles(vec![
                        AccelerationStructureGeometryTrianglesData {
                            flags: GeometryFlags::empty(),
                            vertex_data: Some(position_buffer.into_bytes()),
                            vertex_stride: size_of::<Vec3>() as u32,
                            max_vertex: (mesh.vertices.len() - 1) as u32,
                            index_data: Some(IndexBuffer::U32(index_buffer)),
                            transform_data: None,
                            ..AccelerationStructureGeometryTrianglesData::new(
                                Format::R32G32B32_SFLOAT,
                            )
                        },
                    ]),
                    commands,
                ));
            });
        }

        // Create instance info buffer

        let built_instance_buffer = self.gpu.create_filled_buffer(
            BufferUsage::STORAGE_BUFFER,
            &self
                .instances
                .iter()
                .map(|instance| {
                    let mesh = &meshes[instance.mesh_id.index()];

                    BuiltInstance {
                        vertices: mesh.vertex_buffer.device_address().unwrap().into(),
                        indices: mesh.index_buffer.device_address().unwrap().into(),
                        material: materials
                            .clone()
                            .index(instance.material as u64)
                            .device_address()
                            .unwrap()
                            .into(),
                    }
                })
                .collect::<Vec<BuiltInstance>>(),
        );

        // Create top level acceleration structure

        let instance_buffer = self.gpu.create_filled_buffer(
            BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                | BufferUsage::SHADER_DEVICE_ADDRESS,
            &self
                .instances
                .iter()
                .enumerate()
                .map(|(i, instance)| AccelerationStructureInstance {
                    transform: [
                        instance.transform.row(0).to_array(),
                        instance.transform.row(1).to_array(),
                        instance.transform.row(2).to_array(),
                    ],
                    instance_custom_index_and_mask: Packed24_8::new(i as u32, 0xFF),
                    instance_shader_binding_table_record_offset_and_flags: Packed24_8::new(
                        if self.materials[instance.material].opaque == 1 {
                            0
                        } else {
                            1
                        },
                        0,
                    ),
                    acceleration_structure_reference: mesh_accel_structs[instance.mesh_id.index()]
                        .device_address()
                        .into(),
                })
                .collect::<Vec<AccelerationStructureInstance>>(),
        );

        let (accel_struct, _) = self.gpu.execute(move |commands| {
            self.gpu.create_accel_struct(
                false,
                AccelerationStructureGeometries::Instances(
                    AccelerationStructureGeometryInstancesData::new(
                        AccelerationStructureGeometryInstancesDataType::Values(Some(
                            instance_buffer,
                        )),
                    ),
                ),
                commands,
            )
        });

        // Return

        Scene {
            mesh_accel_structs,
            accel_struct,

            meshes,
            instance_buffer: built_instance_buffer,
            materials,
            textures: self.textures.clone(),
        }
    }
}

fn format_2_to_4(format: Format) -> Format {
    match format {
        Format::R8G8_UNORM => Format::R8G8B8A8_UNORM,
        Format::R8G8_SRGB => Format::R8G8B8A8_SRGB,
        Format::R16G16_UNORM => Format::R16G16B16A16_UNORM,
        Format::R32G32_SFLOAT => Format::R32G32B32A32_SFLOAT,
        _ => unimplemented!(),
    }
}

fn format_3_to_4(format: Format) -> Format {
    match format {
        Format::R8G8B8_UNORM => Format::R8G8B8A8_UNORM,
        Format::R8G8B8_SRGB => Format::R8G8B8A8_SRGB,
        Format::R16G16B16_UNORM => Format::R16G16B16A16_UNORM,
        Format::R32G32B32_SFLOAT => Format::R32G32B32A32_SFLOAT,
        _ => unimplemented!(),
    }
}
