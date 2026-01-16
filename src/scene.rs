use crate::gpu::Gpu;
use glam::{Mat4, Quat, Vec3, vec4};
use gltf::Node;
use gltf::camera::Projection;
use gltf::mesh::Mode;
use gltf::mesh::util::ReadIndices;
use gltf::scene::Transform;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use vulkano::acceleration_structure::{
    AccelerationStructure, AccelerationStructureGeometries,
    AccelerationStructureGeometryInstancesData, AccelerationStructureGeometryInstancesDataType,
    AccelerationStructureGeometryTrianglesData, AccelerationStructureInstance, GeometryFlags,
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

#[derive(Copy, Clone, Default)]
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

    pub fn load_model(&mut self, path: impl AsRef<Path>, transform: Mat4) -> Option<CameraData> {
        fn load_node(
            builder: &mut SceneBuilder,
            meshes: &mut HashMap<usize, MeshId>,
            buffers: &Vec<gltf::buffer::Data>,
            camera_data: &mut Option<CameraData>,
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

            if let Some(camera) = node.camera()
                && camera_data.is_none()
            {
                if let Projection::Perspective(perspective) = camera.projection() {
                    let position = transform.transform_point3(Vec3::ZERO);

                    *camera_data = Some(CameraData {
                        position,
                        look_at: position + transform.transform_vector3(Vec3::NEG_Z),
                        fov: perspective.yfov().to_degrees(),
                    });
                }
            }

            if let Some(mesh) = node.mesh() {
                for primitive in mesh.primitives() {
                    if primitive.mode() != Mode::Triangles {
                        continue;
                    }

                    let mesh_id = meshes.entry(mesh.index()).or_insert_with(|| {
                        let reader = primitive.reader(move |buffer| Some(&buffers[buffer.index()]));

                        let positions: Vec<Vec3> = reader
                            .read_positions()
                            .unwrap()
                            .map(|pos| (Vec3::from_array(pos)))
                            .collect();

                        let normals: Vec<Vec3> = reader
                            .read_normals()
                            .unwrap()
                            .map(|normal| (Vec3::from_array(normal)))
                            .collect();

                        let indices: Vec<u32> = match reader.read_indices().unwrap() {
                            ReadIndices::U8(iter) => iter.map(move |i| i as u32).collect(),
                            ReadIndices::U16(iter) => iter.map(move |i| i as u32).collect(),
                            ReadIndices::U32(iter) => iter.collect(),
                        };

                        let triangles: Vec<Triangle> = indices
                            .iter()
                            .map(|i| Vertex {
                                position: positions[*i as usize],
                                u: 0.0,
                                normal: normals[*i as usize],
                                v: 0.0,
                            })
                            .array_chunks::<3>()
                            .map(|vertices| Triangle(vertices))
                            .collect();

                        builder.create_mesh(&triangles)
                    });

                    builder.add_instance(*mesh_id, transform);
                }
            }

            for child in node.children() {
                load_node(builder, meshes, buffers, camera_data, transform, child);
            }
        }

        let (document, buffers, _images) = gltf::import(path).unwrap();

        let mut meshes = HashMap::new();
        let mut camera_data: Option<CameraData> = None;

        for node in document.default_scene().unwrap().nodes() {
            load_node(
                self,
                &mut meshes,
                &buffers,
                &mut camera_data,
                Mat4::IDENTITY,
                node,
            );
        }

        camera_data
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
                                                ..mesh.first_triangle
                                                    + mesh.triangle_count as DeviceSize,
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
                    instance_shader_binding_table_record_offset_and_flags: Packed24_8::new(0, 0),
                    acceleration_structure_reference: mesh_accel_structs[instance.mesh_id.0]
                        .device_address()
                        .into(),
                })
                .collect::<Vec<AccelerationStructureInstance>>(),
        );

        let (accel_struct, _) = gpu.execute(move |commands| {
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
