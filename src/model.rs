use std::{collections::HashMap, path::Path};

use bevy_mikktspace::{Geometry, generate_tangents};
use glam::{Mat4, Quat, Vec2, Vec3, Vec4, uvec2};
use gltf::{
    Image, Mesh, Node, Primitive, Texture,
    camera::Projection,
    mesh::{Mode, util::ReadIndices},
    scene::Transform,
    texture::{MagFilter, MinFilter, WrappingMode},
};
use vulkano::{
    format::Format,
    image::sampler::{Filter, SamplerAddressMode},
};

use crate::scene::{CameraData, ImageId, Material, MeshId, SceneBuilder, TextureId, Vertex};

struct ModelLoader<'a, 'b> {
    builder: &'a mut SceneBuilder<'b>,

    buffer_data: Vec<gltf::buffer::Data>,
    image_data: Vec<gltf::image::Data>,

    meshes: HashMap<usize, MeshId>,
    images: HashMap<usize, ImageId>,
    textures: HashMap<usize, TextureId>,

    camera_data: Option<CameraData>,
}

impl ModelLoader<'_, '_> {
    fn load_node(&mut self, global_transform: Mat4, node: Node) {
        let local_transform = convert_transform(&node.transform());
        let transform = global_transform * local_transform;

        // Camera
        if let Some(camera) = node.camera()
            && self.camera_data.is_none()
        {
            if let Projection::Perspective(perspective) = camera.projection() {
                let position = transform.transform_point3(Vec3::ZERO);

                self.camera_data = Some(CameraData {
                    position,
                    look_at: position + transform.transform_vector3(Vec3::NEG_Z),
                    fov: perspective.yfov().to_degrees(),
                });
            }
        }

        // Mesh
        if let Some(mesh) = node.mesh() {
            for primitive in mesh.primitives() {
                if primitive.mode() != Mode::Triangles {
                    continue;
                }

                let mesh_id = self.get_mesh_id(&mesh, &primitive);
                let material = self.get_material(&primitive.material());

                self.builder.add_instance(mesh_id, transform, material);
            }
        }

        // Children
        for child in node.children() {
            self.load_node(transform, child);
        }
    }

    fn get_mesh_id(&mut self, mesh: &Mesh, primitive: &Primitive) -> MeshId {
        *self.meshes.entry(mesh.index()).or_insert({
            let reader = primitive.reader(|buffer| Some(&self.buffer_data[buffer.index()]));

            let positions: Vec<Vec3> =
                bytemuck::cast_vec(reader.read_positions().unwrap().collect::<Vec<[f32; 3]>>());

            let normals: Vec<Vec3> =
                bytemuck::cast_vec(reader.read_normals().unwrap().collect::<Vec<[f32; 3]>>());

            let uvs: Vec<Vec2> = bytemuck::cast_vec(
                reader
                    .read_tex_coords(0)
                    .unwrap()
                    .into_f32()
                    .collect::<Vec<[f32; 2]>>(),
            );

            let indices: Vec<u32> = match reader.read_indices().unwrap() {
                ReadIndices::U8(iter) => iter.map(move |i| i as u32).collect(),
                ReadIndices::U16(iter) => iter.map(move |i| i as u32).collect(),
                ReadIndices::U32(iter) => iter.collect(),
            };

            let tangents: Vec<Vec4> = match reader.read_tangents() {
                Some(tangents) => bytemuck::cast_vec(tangents.collect()),
                None => {
                    let mut tangents = vec![Vec4::ZERO; positions.len()];

                    let mut geometry = MeshGeometry {
                        positions: &positions,
                        normals: &normals,
                        uvs: &uvs,
                        indices: &indices,
                        tangents: &mut tangents,
                    };

                    assert!(generate_tangents(&mut geometry));

                    tangents
                }
            };

            self.builder.create_mesh(
                positions,
                normals
                    .iter()
                    .zip(uvs)
                    .zip(tangents)
                    .map(move |((normal, uv), tangent)| Vertex {
                        normal: normal.extend(0.0),
                        uv: uv.extend(0.0).extend(0.0),
                        tangent,
                    })
                    .collect(),
                indices,
            )
        })
    }

    fn get_image_id(&mut self, img: &Image, srgb: bool) -> ImageId {
        *self.images.entry(img.index()).or_insert_with(|| {
            let data = &self.image_data[img.index()];
            let format = convert_format(data.format);

            self.builder.create_image(
                uvec2(data.width, data.height),
                if srgb { to_srgb(format) } else { format },
                &data.pixels,
            )
        })
    }

    fn get_texture_id(&mut self, info: Option<Texture>, srgb: bool) -> TextureId {
        match info {
            Some(texture) => {
                let index = texture.index();

                if let Some(id) = self.textures.get(&index) {
                    return *id;
                }

                let image_id = self.get_image_id(&texture.source(), srgb);
                let sampler = &texture.sampler();

                let id = self.builder.create_texture(
                    image_id,
                    convert_min(sampler.min_filter().unwrap_or(MinFilter::Nearest)),
                    convert_mag(sampler.mag_filter().unwrap_or(MagFilter::Nearest)),
                    convert_wrap(sampler.wrap_s()),
                    convert_wrap(sampler.wrap_t()),
                );

                self.textures.insert(index, id);

                id
            }
            None => TextureId::empty(),
        }
    }

    fn get_material(&mut self, mat: &gltf::Material) -> Material {
        let mut material = Material {
            albedo_factor: Vec4::from_array(mat.pbr_metallic_roughness().base_color_factor()),
            albedo_texture: self.get_texture_id(
                mat.pbr_metallic_roughness()
                    .base_color_texture()
                    .map(move |info| info.texture()),
                true,
            ),

            metallic_factor: mat.pbr_metallic_roughness().metallic_factor(),
            roughness_factor: mat.pbr_metallic_roughness().roughness_factor(),
            metallic_roughness_texture: self.get_texture_id(
                mat.pbr_metallic_roughness()
                    .metallic_roughness_texture()
                    .map(move |info| info.texture()),
                false,
            ),

            emissive_factor: Vec3::from_array(mat.emissive_factor()).extend(0.0),
            emissive_texture: self
                .get_texture_id(mat.emissive_texture().map(move |info| info.texture()), true),

            normal_texture: self
                .get_texture_id(mat.normal_texture().map(move |info| info.texture()), false),

            ..Default::default()
        };

        if let Some(cc) = mat.clearcoat() {
            material.clearcoat_factor = cc.clearcoat_factor();
            material.clearcoat_texture = self.get_texture_id(
                cc.clearcoat_texture().map(move |info| info.texture()),
                false,
            );

            material.clearcoat_roughness_factor = cc.clearcoat_roughness_factor();
            material.clearcoat_roughness_texture = self.get_texture_id(
                cc.clearcoat_roughness_texture()
                    .map(move |info| info.texture()),
                false,
            );
        }

        material
    }
}

pub fn load_model(
    builder: &mut SceneBuilder,
    path: impl AsRef<Path>,
    transform: Mat4,
) -> Option<CameraData> {
    let (document, buffers, images) = gltf::import(path).unwrap();

    let mut loader = ModelLoader {
        builder,
        buffer_data: buffers,
        image_data: images,
        meshes: HashMap::new(),
        images: HashMap::new(),
        textures: HashMap::new(),
        camera_data: None,
    };

    for node in document.default_scene().as_ref().unwrap().nodes() {
        loader.load_node(transform, node);
    }

    loader.camera_data
}

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

fn convert_transform(transform: &Transform) -> Mat4 {
    match transform {
        Transform::Matrix { matrix } => Mat4::from_cols_array_2d(&matrix),
        Transform::Decomposed {
            translation,
            rotation,
            scale,
        } => Mat4::from_scale_rotation_translation(
            Vec3::from_array(*scale),
            Quat::from_array(*rotation),
            Vec3::from_array(*translation),
        ),
    }
}

fn convert_format(format: gltf::image::Format) -> Format {
    match format {
        gltf::image::Format::R8 => Format::R8_UNORM,
        gltf::image::Format::R8G8 => Format::R8G8_UNORM,
        gltf::image::Format::R8G8B8 => Format::R8G8B8_UNORM,
        gltf::image::Format::R8G8B8A8 => Format::R8G8B8A8_UNORM,
        gltf::image::Format::R16 => Format::R16_UNORM,
        gltf::image::Format::R16G16 => Format::R16G16_UNORM,
        gltf::image::Format::R16G16B16 => Format::R16G16B16_UNORM,
        gltf::image::Format::R16G16B16A16 => Format::R16G16B16A16_UNORM,
        gltf::image::Format::R32G32B32FLOAT => Format::R32G32B32_SFLOAT,
        gltf::image::Format::R32G32B32A32FLOAT => Format::R32G32B32A32_SFLOAT,
    }
}

fn to_srgb(format: Format) -> Format {
    match format {
        Format::R8_UNORM => Format::R8_SRGB,
        Format::R8G8_UNORM => Format::R8G8_SRGB,
        Format::R8G8B8_UNORM => Format::R8G8B8_SRGB,
        Format::R8G8B8A8_UNORM => Format::R8G8B8A8_SRGB,
        Format::R16_UNORM => unimplemented!("16 bit textures can't be sRGB"),
        Format::R16G16_UNORM => unimplemented!("16 bit textures can't be sRGB"),
        Format::R16G16B16_UNORM => unimplemented!("16 bit textures can't be sRGB"),
        Format::R16G16B16A16_UNORM => unimplemented!("16 bit textures can't be sRGB"),
        Format::R32G32B32_SFLOAT => unimplemented!("32 bit textures can't be sRGB"),
        Format::R32G32B32A32_SFLOAT => unimplemented!("32 bit textures can't be sRGB"),
        _ => unimplemented!("invalid GLTF image format"),
    }
}

fn convert_min(min: MinFilter) -> Filter {
    match min {
        MinFilter::Nearest => Filter::Nearest,
        MinFilter::Linear => Filter::Linear,
        MinFilter::NearestMipmapNearest => Filter::Nearest,
        MinFilter::LinearMipmapNearest => Filter::Linear,
        MinFilter::NearestMipmapLinear => Filter::Nearest,
        MinFilter::LinearMipmapLinear => Filter::Linear,
    }
}

fn convert_mag(mag: MagFilter) -> Filter {
    match mag {
        MagFilter::Nearest => Filter::Nearest,
        MagFilter::Linear => Filter::Linear,
    }
}

fn convert_wrap(wrap: WrappingMode) -> SamplerAddressMode {
    match wrap {
        WrappingMode::ClampToEdge => SamplerAddressMode::ClampToEdge,
        WrappingMode::MirroredRepeat => SamplerAddressMode::MirroredRepeat,
        WrappingMode::Repeat => SamplerAddressMode::Repeat,
    }
}
