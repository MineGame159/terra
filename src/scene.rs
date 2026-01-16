use glam::{Mat4, Quat, Vec3};
use gltf::Node;
use gltf::mesh::Mode;
use gltf::mesh::util::ReadIndices;
use gltf::scene::Transform;
use std::path::Path;
use vulkano::buffer::BufferContents;

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
pub struct Vertex {
    pub position: Vec3,
    pub u: f32,
    pub normal: Vec3,
    pub v: f32,
}

#[derive(BufferContents, Copy, Clone)]
#[repr(transparent)]
pub struct Triangle(pub [Vertex; 3]);

#[derive(Copy, Clone)]
pub struct CameraData {
    pub position: Vec3,
    pub look_at: Vec3,
    pub fov: f32,
}

pub fn load_model(path: impl AsRef<Path>) -> Vec<Triangle> {
    let (document, buffers, _images) = gltf::import(path).unwrap();

    let mut triangles: Vec<Triangle> = vec![];

    for node in document.default_scene().unwrap().nodes() {
        load_node(&buffers, &mut triangles, Mat4::IDENTITY, node);
    }

    triangles
}

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
                        position: positions[*i as usize],
                        u: 0.0,
                        normal: normals[*i as usize],
                        v: 0.0,
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
