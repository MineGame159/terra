use std::{borrow::Cow, sync::Arc};

use bevy_mikktspace::Geometry;
use glam::{Mat4, Quat, Vec2, Vec3, Vec3A, Vec4};
use vulkano::{
    buffer::{BufferContents, BufferUsage, Subbuffer},
    image::{sampler::Sampler, view::ImageView},
};

use crate::gpu::Gpu;

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
pub struct Vertex {
    pub uv: Vec4,
    pub normal: Vec3A,
    pub tangent: Vec4,
}

#[derive(Clone, PartialEq)]
pub struct Mesh {
    pub indices: Subbuffer<[u32]>,
    pub positions: Subbuffer<[Vec3]>,
    pub vertices: Subbuffer<[Vertex]>,
}

#[profiling::all_functions]
impl Mesh {
    pub fn new(
        gpu: &Gpu,
        indices: &[u32],
        positions: &[Vec3],
        uvs: &[Vec2],
        normals: &[Vec3],
        tangents: Option<&[Vec4]>,
    ) -> Mesh {
        let tangents = match tangents {
            Some(tangents) => Cow::Borrowed(tangents),
            None => Cow::Owned(generate_tangents(indices, positions, uvs, normals)),
        };

        Mesh {
            indices: gpu.create_filled_buffer(
                BufferUsage::VERTEX_BUFFER
                    | BufferUsage::SHADER_DEVICE_ADDRESS
                    | BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY,
                indices,
            ),
            positions: gpu.create_filled_buffer(
                BufferUsage::VERTEX_BUFFER
                    | BufferUsage::SHADER_DEVICE_ADDRESS
                    | BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY,
                positions,
            ),
            vertices: gpu.create_filled_buffer(
                BufferUsage::VERTEX_BUFFER
                    | BufferUsage::SHADER_DEVICE_ADDRESS
                    | BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY,
                &normals
                    .iter()
                    .zip(uvs)
                    .zip(tangents.as_ref())
                    .map(move |((normal, uv), tangent)| Vertex {
                        uv: uv.extend(0.0).extend(0.0),
                        normal: (*normal).into(),
                        tangent: *tangent,
                    })
                    .collect::<Vec<Vertex>>(),
            ),
        }
    }
}

pub type Texture = Option<(Arc<ImageView>, Arc<Sampler>)>;

#[derive(Clone, PartialEq)]
pub struct Material {
    pub albedo_factor: Vec4,
    pub albedo_texture: Texture,

    pub metallic_factor: f32,
    pub roughness_factor: f32,
    pub metallic_roughness_texture: Texture,

    pub emissive_factor: Vec3,
    pub emissive_texture: Texture,

    pub ior: f32,

    pub specular_factor: f32,
    pub specular_texture: Texture,

    pub specular_color_factor: Vec3,
    pub specular_color_texture: Texture,

    pub clearcoat_factor: f32,
    pub clearcoat_texture: Texture,

    pub clearcoat_roughness_factor: f32,
    pub clearcoat_roughness_texture: Texture,

    pub normal_texture: Texture,

    pub opaque: u32,
}

impl Default for Material {
    fn default() -> Self {
        Self {
            albedo_factor: Vec4::ONE,
            albedo_texture: None,

            metallic_factor: 0.0,
            roughness_factor: 0.5,
            metallic_roughness_texture: None,

            emissive_factor: Vec3::ZERO,
            emissive_texture: None,

            ior: 1.5,

            specular_factor: 1.0,
            specular_texture: None,

            specular_color_factor: Vec3::ONE,
            specular_color_texture: None,

            clearcoat_factor: 0.0,
            clearcoat_texture: None,

            clearcoat_roughness_factor: 0.0,
            clearcoat_roughness_texture: None,

            normal_texture: None,

            opaque: 0,
        }
    }
}

// --- Components ---

#[derive(PartialEq, Clone)]
pub struct Node {
    pub position: Vec3,
    pub rotation: Quat,
    pub scale: Vec3,
}

impl Node {
    pub fn transform(&self) -> Mat4 {
        Mat4::from_scale_rotation_translation(self.scale, self.rotation, self.position)
    }
}

impl From<Mat4> for Node {
    fn from(value: Mat4) -> Self {
        let (scale, rotation, position) = value.to_scale_rotation_translation();

        Node {
            position,
            rotation,
            scale,
        }
    }
}

#[derive(PartialEq, Clone)]
pub struct MeshInstance {
    pub mesh: Mesh,
    pub material: Material,
}

#[derive(PartialEq, Clone)]
pub struct Camera {
    pub env_map_path: String,

    pub fov: f32,
}

#[derive(PartialEq, Clone)]
pub struct PointLight {
    pub color: Vec3,
    pub range: f32,
}

#[derive(PartialEq, Clone)]
pub struct SpotLight {
    pub color: Vec3,
    pub range: f32,
    pub inner_cone_angle: f32,
    pub outer_cone_angle: f32,
}

#[derive(PartialEq, Clone)]
pub struct DirectionalLight {
    pub color: Vec3,
}

// --- Tangent generation ---

struct MeshGeometry<'a> {
    positions: &'a [Vec3],
    normals: &'a [Vec3],
    uvs: &'a [Vec2],
    indices: &'a [u32],

    tangents: &'a mut [Vec4],
}

impl Geometry for MeshGeometry<'_> {
    fn num_faces(&self) -> usize {
        self.indices.len() / 3
    }

    fn num_vertices_of_face(&self, _face: usize) -> usize {
        3
    }

    fn position(&self, face: usize, vert: usize) -> [f32; 3] {
        let index = self.indices[face * 3 + vert] as usize;
        self.positions[index].to_array()
    }

    fn normal(&self, face: usize, vert: usize) -> [f32; 3] {
        let index = self.indices[face * 3 + vert] as usize;
        self.normals[index].to_array()
    }

    fn tex_coord(&self, face: usize, vert: usize) -> [f32; 2] {
        let index = self.indices[face * 3 + vert] as usize;
        self.uvs[index].to_array()
    }

    fn set_tangent_encoded(&mut self, tangent: [f32; 4], face: usize, vert: usize) {
        let index = self.indices[face * 3 + vert] as usize;
        self.tangents[index] = Vec4::from_array(tangent);
    }
}

#[profiling::function]
fn generate_tangents(
    indices: &[u32],
    positions: &[Vec3],
    uvs: &[Vec2],
    normals: &[Vec3],
) -> Vec<Vec4> {
    let mut tangents = vec![Vec4::ZERO; positions.len()];

    let mut geometry = MeshGeometry {
        positions: &positions,
        normals: &normals,
        uvs: &uvs,
        indices: &indices,
        tangents: &mut tangents,
    };

    assert!(bevy_mikktspace::generate_tangents(&mut geometry));

    tangents
}
