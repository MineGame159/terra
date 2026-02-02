use std::{collections::HashMap, path::Path, sync::Arc};

use glam::{Mat4, Quat, Vec2, Vec3, Vec4, uvec2};
use gltf::{
    Image, Material, Mesh, Node, Primitive, Texture,
    camera::Projection,
    khr_lights_punctual::Kind,
    material::AlphaMode,
    mesh::{Mode, util::ReadIndices},
    scene::Transform,
    texture::{MagFilter, MinFilter, WrappingMode},
};
use hecs::World;
use vulkano::{
    format::Format,
    image::{
        sampler::{Filter, Sampler, SamplerAddressMode, SamplerCreateInfo},
        view::ImageView,
    },
};

use crate::{gpu::Gpu, world};

struct ModelLoader<'a> {
    gpu: &'a Gpu,
    world: &'a mut World,

    buffer_data: Vec<gltf::buffer::Data>,
    image_data: Vec<gltf::image::Data>,

    meshes: HashMap<usize, world::Mesh>,
    images: HashMap<usize, Arc<ImageView>>,
    textures: HashMap<usize, (Arc<ImageView>, Arc<Sampler>)>,
}

#[profiling::all_functions]
impl ModelLoader<'_> {
    fn load_node(&mut self, global_transform: Mat4, node: Node) {
        let local_transform = convert_transform(&node.transform());
        let transform = global_transform * local_transform;

        // Camera
        if let Some(camera) = node.camera() {
            if let Projection::Perspective(perspective) = camera.projection() {
                self.world.spawn((
                    world::Node::from(transform),
                    world::Camera {
                        env_map_path: String::new(),
                        fov: perspective.yfov().to_degrees(),
                    },
                ));
            }
        }

        // Mesh
        if let Some(mesh) = node.mesh() {
            for primitive in mesh.primitives() {
                if primitive.mode() != Mode::Triangles {
                    continue;
                }

                let mesh = self.get_mesh(&mesh, &primitive).clone();
                let material = self.get_material(&primitive.material());

                self.world.spawn((
                    world::Node::from(transform),
                    world::MeshInstance { mesh, material },
                ));
            }
        }

        // Light
        if let Some(light) = node.light() {
            let color = Vec3::from_array(light.color()) * (light.intensity() / 683.0);

            match light.kind() {
                Kind::Point => self.world.spawn((
                    world::Node::from(transform),
                    world::PointLight {
                        color,
                        range: light.range().unwrap_or(0.0),
                    },
                )),
                Kind::Spot {
                    inner_cone_angle,
                    outer_cone_angle,
                } => self.world.spawn((
                    world::Node::from(transform),
                    world::SpotLight {
                        color,
                        range: light.range().unwrap_or(0.0),
                        inner_cone_angle,
                        outer_cone_angle,
                    },
                )),
                Kind::Directional => self.world.spawn((
                    world::Node::from(transform),
                    world::DirectionalLight { color },
                )),
            };
        }

        // Children
        for child in node.children() {
            self.load_node(transform, child);
        }
    }

    fn get_mesh(&mut self, mesh: &Mesh, primitive: &Primitive) -> &world::Mesh {
        self.meshes
            .entry(mesh.index() * 4096 + primitive.index())
            .or_insert_with(|| {
                let reader = primitive.reader(|buffer| Some(&self.buffer_data[buffer.index()]));

                let indices: Vec<u32> = {
                    profiling::scope!("indices");
                    match reader.read_indices().unwrap() {
                        ReadIndices::U8(iter) => iter.map(move |i| i as u32).collect(),
                        ReadIndices::U16(iter) => iter.map(move |i| i as u32).collect(),
                        ReadIndices::U32(iter) => iter.collect(),
                    }
                };

                let positions: Vec<Vec3> = {
                    profiling::scope!("positions");
                    bytemuck::cast_vec(reader.read_positions().unwrap().collect::<Vec<[f32; 3]>>())
                };

                let uvs: Vec<Vec2> = {
                    profiling::scope!("uvs");
                    bytemuck::cast_vec(
                        reader
                            .read_tex_coords(0)
                            .unwrap()
                            .into_f32()
                            .collect::<Vec<[f32; 2]>>(),
                    )
                };

                let normals: Vec<Vec3> = {
                    profiling::scope!("normals");
                    bytemuck::cast_vec(reader.read_normals().unwrap().collect::<Vec<[f32; 3]>>())
                };

                let tangents: Option<Vec<Vec4>> = {
                    profiling::scope!("tangents");
                    match reader.read_tangents() {
                        Some(iter) => Some(bytemuck::cast_vec(iter.collect::<Vec<[f32; 4]>>())),
                        None => None,
                    }
                };

                world::Mesh::new(
                    self.gpu,
                    &indices,
                    &positions,
                    &uvs,
                    &normals,
                    tangents.as_deref(),
                )
            })
    }

    fn get_material(&mut self, mat: &Material) -> world::Material {
        let mut material = world::Material {
            albedo_factor: Vec4::from_array(mat.pbr_metallic_roughness().base_color_factor()),
            albedo_texture: self.get_texture(
                mat.pbr_metallic_roughness()
                    .base_color_texture()
                    .map(move |info| info.texture()),
                true,
            ),

            metallic_factor: mat.pbr_metallic_roughness().metallic_factor(),
            roughness_factor: mat.pbr_metallic_roughness().roughness_factor(),
            metallic_roughness_texture: self.get_texture(
                mat.pbr_metallic_roughness()
                    .metallic_roughness_texture()
                    .map(move |info| info.texture()),
                false,
            ),

            emissive_factor: Vec3::from_array(mat.emissive_factor()),
            emissive_texture: self
                .get_texture(mat.emissive_texture().map(move |info| info.texture()), true),

            normal_texture: self
                .get_texture(mat.normal_texture().map(move |info| info.texture()), false),
            normal_scale: mat.normal_texture().map_or(1.0, move |info| info.scale()),

            opaque: if mat.alpha_mode() == AlphaMode::Opaque {
                1
            } else {
                0
            },

            ..Default::default()
        };

        if let Some(strength) = mat.emissive_strength() {
            material.emissive_factor *= strength;
        }

        if let Some(ior) = mat.ior() {
            material.ior = ior;
        }

        if let Some(spec) = mat.specular() {
            material.specular_factor = spec.specular_factor();
            material.specular_texture = self.get_texture(
                spec.specular_texture().map(move |info| info.texture()),
                false,
            );

            material.specular_color_factor = Vec3::from_array(spec.specular_color_factor());
            material.specular_color_texture = self.get_texture(
                spec.specular_color_texture()
                    .map(move |info| info.texture()),
                true,
            );
        }

        if let Some(cc) = mat.clearcoat() {
            material.clearcoat_factor = cc.clearcoat_factor();
            material.clearcoat_texture = self.get_texture(
                cc.clearcoat_texture().map(move |info| info.texture()),
                false,
            );

            material.clearcoat_roughness_factor = cc.clearcoat_roughness_factor();
            material.clearcoat_roughness_texture = self.get_texture(
                cc.clearcoat_roughness_texture()
                    .map(move |info| info.texture()),
                false,
            );
        }

        material
    }

    fn get_texture(&mut self, info: Option<Texture>, srgb: bool) -> world::Texture {
        match info {
            Some(texture) => {
                let index = texture.index();

                if let Some((view, sampler)) = self.textures.get(&index) {
                    return Some((view.clone(), sampler.clone()));
                }

                let view = self.get_image_view(&texture.source(), srgb);
                let sampler = &texture.sampler();

                let sampler = Sampler::new(
                    self.gpu.device.clone(),
                    SamplerCreateInfo {
                        min_filter: convert_min(sampler.min_filter().unwrap_or(MinFilter::Nearest)),
                        mag_filter: convert_mag(sampler.mag_filter().unwrap_or(MagFilter::Nearest)),
                        address_mode: [
                            convert_wrap(sampler.wrap_s()),
                            convert_wrap(sampler.wrap_t()),
                            SamplerAddressMode::Repeat,
                        ],
                        lod: 0.0..=1.0,
                        ..SamplerCreateInfo::simple_repeat_linear_no_mipmap()
                    },
                )
                .unwrap();

                self.textures.insert(index, (view.clone(), sampler.clone()));

                Some((view, sampler))
            }
            None => None,
        }
    }

    fn get_image_view(&mut self, image: &Image, srgb: bool) -> Arc<ImageView> {
        self.images
            .entry(image.index())
            .or_insert_with(|| {
                let data = &self.image_data[image.index()];
                let format = convert_format(data.format);

                self.gpu.create_sampled_filled_image(
                    uvec2(data.width, data.height),
                    if srgb { to_srgb(format) } else { format },
                    &data.pixels,
                )
            })
            .clone()
    }
}

#[profiling::function]
pub fn load(path: impl AsRef<Path>, gpu: &Gpu, world: &mut World) -> Result<(), String> {
    let (document, buffers, images) = {
        profiling::scope!("gltf::import");
        match gltf::import(path) {
            Ok(import) => import,
            Err(err) => return Err(format!("failed to import GLTF model: {}", err)),
        }
    };

    let mut loader = ModelLoader {
        gpu,
        world,
        buffer_data: buffers,
        image_data: images,
        meshes: HashMap::new(),
        images: HashMap::new(),
        textures: HashMap::new(),
    };

    for node in document.default_scene().as_ref().unwrap().nodes() {
        loader.load_node(Mat4::IDENTITY, node);
    }

    Ok(())
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
