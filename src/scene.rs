use crate::gpu::Gpu;
use glam::{Mat4, Quat, Vec3, vec4};
use gltf::Node;
use gltf::mesh::Mode;
use gltf::mesh::util::ReadIndices;
use gltf::scene::Transform;
use std::path::Path;
use std::sync::Arc;
use vulkano::acceleration_structure::{
    AccelerationStructure, AccelerationStructureGeometries,
    AccelerationStructureGeometryInstancesData, AccelerationStructureGeometryInstancesDataType,
    AccelerationStructureGeometryTrianglesData, AccelerationStructureInstance, GeometryFlags,
    GeometryInstanceFlags,
};
use vulkano::buffer::{BufferContents, BufferUsage, Subbuffer};
use vulkano::format::Format;
use vulkano::{DeviceSize, Packed24_8};

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

pub struct Scene {
    pub mesh_accel_structs: Vec<Arc<AccelerationStructure>>,
    pub accel_struct: Arc<AccelerationStructure>,
    pub triangle_buffer: Subbuffer<[Triangle]>,
}

#[derive(Copy, Clone)]
pub struct MeshId(usize);

struct Mesh {
    first_triangle: u64,
    triangle_count: u32,
}

struct Instance {
    mesh_id: MeshId,
    transform: Mat4,
}

pub struct SceneBuilder {
    meshes: Vec<Mesh>,
    instances: Vec<Instance>,
    triangles: Vec<Triangle>,
}

impl SceneBuilder {
    pub fn new() -> SceneBuilder {
        SceneBuilder {
            meshes: Vec::with_capacity(8),
            instances: Vec::with_capacity(8),
            triangles: Vec::with_capacity(1024),
        }
    }

    pub fn create_mesh(&mut self, triangles: &[Triangle]) -> MeshId {
        self.meshes.push(Mesh {
            first_triangle: self.triangles.len() as u64,
            triangle_count: triangles.len() as u32,
        });

        self.triangles.extend_from_slice(triangles);

        MeshId(self.meshes.len() - 1)
    }

    pub fn add_instance(&mut self, mesh_id: MeshId, transform: Mat4) {
        assert_eq!(transform.row(3), vec4(0.0, 0.0, 0.0, 1.0));

        self.instances.push(Instance { mesh_id, transform });
    }

    pub fn load_model(&mut self, path: impl AsRef<Path>, transform: Mat4) {
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

        // Load model triangles

        let (document, buffers, _images) = gltf::import(path).unwrap();

        let mut triangles: Vec<Triangle> = vec![];

        for node in document.default_scene().unwrap().nodes() {
            load_node(&buffers, &mut triangles, Mat4::IDENTITY, node);
        }

        // Create mesh and add instance

        let mesh_id = self.create_mesh(&triangles);
        self.add_instance(mesh_id, transform);
    }

    pub fn build(&self, gpu: &Gpu) -> Scene {
        let triangle_buffer = gpu.create_filled_buffer(
            BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                | BufferUsage::SHADER_DEVICE_ADDRESS
                | BufferUsage::STORAGE_BUFFER,
            &self.triangles,
        );

        // Create mesh (bottom level) acceleration structures

        let mut mesh_accel_structs = Vec::with_capacity(self.meshes.len());

        for i in 0..self.meshes.len() {
            let mesh = &self.meshes[i];

            gpu.execute(|commands| {
                mesh_accel_structs.push(gpu.create_accel_struct(
                    true,
                    AccelerationStructureGeometries::Triangles(vec![
                            AccelerationStructureGeometryTrianglesData {
                                flags: GeometryFlags::OPAQUE,
                                vertex_data: Some(
                                    triangle_buffer
                                        .clone()
                                        .slice(
                                            mesh.first_triangle as DeviceSize
                                                ..mesh.triangle_count as DeviceSize,
                                        )
                                        .into_bytes(),
                                ),
                                vertex_stride: size_of::<Vertex>() as u32,
                                max_vertex: mesh.triangle_count * 3 - 1,
                                index_data: None,
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

        // Create top level acceleration structure

        let instance_buffer = gpu.create_filled_buffer(
            BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                | BufferUsage::SHADER_DEVICE_ADDRESS,
            &self
                .instances
                .iter()
                .map(|instance| AccelerationStructureInstance {
                    transform: [
                        instance.transform.row(0).to_array(),
                        instance.transform.row(1).to_array(),
                        instance.transform.row(2).to_array(),
                    ],
                    instance_custom_index_and_mask: Packed24_8::new(
                        self.meshes[instance.mesh_id.0].first_triangle as u32,
                        0xFF,
                    ),
                    instance_shader_binding_table_record_offset_and_flags: Packed24_8::new(
                        0,
                        GeometryInstanceFlags::TRIANGLE_FACING_CULL_DISABLE.into(),
                    ),
                    acceleration_structure_reference: mesh_accel_structs[instance.mesh_id.0]
                        .device_address()
                        .into(),
                })
                .collect::<Vec<AccelerationStructureInstance>>(),
        );

        let accel_struct = gpu.execute(move |commands| {
            gpu.create_accel_struct(
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
            triangle_buffer,
        }
    }
}
