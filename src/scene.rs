use crate::gpu::Gpu;
use glam::{Mat4, Quat, Vec3, Vec4, vec4};
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
use vulkano::buffer::{BufferContents, BufferUsage, IndexBuffer, Subbuffer};
use vulkano::format::Format;
use vulkano::{DeviceAddress, Packed24_8};

#[derive(BufferContents, Copy, Clone)]
#[repr(C)]
pub struct Vertex {
    pub normal: Vec4,
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
}

pub struct Scene {
    pub mesh_accel_structs: Vec<Arc<AccelerationStructure>>,
    pub accel_struct: Arc<AccelerationStructure>,

    pub meshes: Vec<BuiltMesh>,
    pub instance_buffer: Subbuffer<[BuiltInstance]>,
}

#[derive(Copy, Clone)]
pub struct MeshId(usize);

struct Mesh {
    positions: Vec<Vec3>,
    vertices: Vec<Vertex>,
    indices: Vec<u32>,
}

struct Instance {
    mesh_id: MeshId,
    transform: Mat4,
}

pub struct SceneBuilder {
    meshes: Vec<Mesh>,
    instances: Vec<Instance>,
}

impl SceneBuilder {
    pub fn new() -> SceneBuilder {
        SceneBuilder {
            meshes: Vec::with_capacity(8),
            instances: Vec::with_capacity(8),
        }
    }

    pub fn create_mesh<'a>(
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

                        let positions: Vec<Vec3> = bytemuck::cast_vec(
                            reader.read_positions().unwrap().collect::<Vec<[f32; 3]>>(),
                        );

                        let normals: Vec<Vec3> = bytemuck::cast_vec(
                            reader.read_normals().unwrap().collect::<Vec<[f32; 3]>>(),
                        );

                        let indices: Vec<u32> = match reader.read_indices().unwrap() {
                            ReadIndices::U8(iter) => iter.map(move |i| i as u32).collect(),
                            ReadIndices::U16(iter) => iter.map(move |i| i as u32).collect(),
                            ReadIndices::U32(iter) => iter.collect(),
                        };

                        builder.create_mesh(
                            positions,
                            normals
                                .iter()
                                .map(move |normal| Vertex {
                                    normal: normal.extend(0.0),
                                })
                                .collect(),
                            indices,
                        )
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
                transform,
                node,
            );
        }

        camera_data
    }

    pub fn build(&self, gpu: &Gpu) -> Scene {
        // Create mesh (bottom level) acceleration structures

        let mut mesh_accel_structs = Vec::with_capacity(self.meshes.len());
        let mut meshes = Vec::with_capacity(self.meshes.len());

        for i in 0..self.meshes.len() {
            let mesh = &self.meshes[i];

            let position_buffer = gpu.create_filled_buffer(
                BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                    | BufferUsage::SHADER_DEVICE_ADDRESS,
                &mesh.positions,
            );

            let vertex_buffer = gpu.create_filled_buffer(
                BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                    | BufferUsage::SHADER_DEVICE_ADDRESS,
                &mesh.vertices,
            );

            let index_buffer = gpu.create_filled_buffer(
                BufferUsage::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY
                    | BufferUsage::SHADER_DEVICE_ADDRESS,
                &mesh.indices,
            );

            meshes.push(BuiltMesh {
                vertex_buffer,
                index_buffer: index_buffer.clone(),
            });

            gpu.execute(|commands| {
                mesh_accel_structs.push(gpu.create_accel_struct(
                    true,
                    AccelerationStructureGeometries::Triangles(vec![
                        AccelerationStructureGeometryTrianglesData {
                            flags: GeometryFlags::OPAQUE,
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

        let built_instance_buffer = gpu.create_filled_buffer(
            BufferUsage::STORAGE_BUFFER,
            &self
                .instances
                .iter()
                .map(|instance| {
                    let mesh = &meshes[instance.mesh_id.0];

                    BuiltInstance {
                        vertices: mesh.vertex_buffer.device_address().unwrap().into(),
                        indices: mesh.index_buffer.device_address().unwrap().into(),
                    }
                })
                .collect::<Vec<BuiltInstance>>(),
        );

        // Create top level acceleration structure

        let instance_buffer = gpu.create_filled_buffer(
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

            meshes,
            instance_buffer: built_instance_buffer,
        }
    }
}
