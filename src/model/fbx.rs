use std::{collections::HashMap, io::Cursor, path::Path, sync::Arc};

use glam::{Mat4, U8Vec4, Vec2, Vec3, Vec4, Vec4Swizzles, uvec2, vec2, vec3, vec4};
use hecs::World;
use image::{ColorType, DynamicImage, GenericImageView, ImageReader};
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

    meshes: HashMap<(u32, u32), world::Mesh>,
}

#[profiling::all_functions]
impl ModelLoader<'_> {
    fn load_node(&mut self, node: &ufbx::Node) {
        if let Some(camera) = &node.camera {
            // Camera
            if camera.projection_mode == ufbx::ProjectionMode::Perspective {
                self.world.spawn((
                    world::Node::from(convert_matrix(node.node_to_world)),
                    world::Camera {
                        env_map_path: String::new(),
                        fov: camera.field_of_view_deg.y as f32,
                    },
                ));
            }
        }

        // Mesh
        if let Some(mesh) = &node.mesh {
            for part in &mesh.material_parts {
                let mesh = self.get_mesh(mesh, part).clone();
                let material = self.get_material(&node.materials[part.index as usize]);

                self.world.spawn((
                    world::Node::from(convert_matrix(node.node_to_world)),
                    world::MeshInstance { mesh, material },
                ));
            }
        }

        // Light
        if let Some(light) = &node.light {
            match light.type_ {
                ufbx::LightType::Point => {
                    self.world.spawn((
                        world::Node::from(convert_matrix(node.node_to_world)),
                        world::PointLight {
                            color: convert_vec3(light.color) * light.intensity as f32,
                            range: 0.0,
                        },
                    ));
                }
                ufbx::LightType::Spot => {
                    self.world.spawn((
                        world::Node::from(convert_matrix(node.node_to_world)),
                        world::SpotLight {
                            color: convert_vec3(light.color) * light.intensity as f32,
                            range: 0.0,
                            inner_cone_angle: light.inner_angle as f32,
                            outer_cone_angle: light.outer_angle as f32,
                        },
                    ));
                }
                ufbx::LightType::Directional => {
                    self.world.spawn((
                        world::Node::from(convert_matrix(node.node_to_world)),
                        world::DirectionalLight {
                            color: convert_vec3(light.color) * light.intensity as f32,
                        },
                    ));
                }
                _ => {}
            };
        }
    }

    fn get_mesh(&mut self, mesh: &ufbx::Mesh, part: &ufbx::MeshPart) -> &world::Mesh {
        self.meshes
            .entry((mesh.element.element_id, part.index))
            .or_insert_with(|| {
                let mut tri_indices = vec![0u32; mesh.max_face_triangles * 3];

                let mut positions = Vec::with_capacity(128);
                let mut uvs = Vec::with_capacity(128);
                let mut normals = Vec::with_capacity(128);
                let mut tangents = Vec::with_capacity(128);

                for &face_index in &part.face_indices {
                    let face = mesh.faces[face_index as usize];

                    let num_tris = mesh.triangulate_face(&mut tri_indices, face);
                    let num_tri_corners = (num_tris * 3) as usize;

                    for &index in &tri_indices[..num_tri_corners] {
                        let i = index as usize;

                        positions.push(convert_vec3(mesh.vertex_position[i]));
                        uvs.push(convert_vec2(mesh.vertex_uv[i]));
                        normals.push(convert_vec3(mesh.vertex_normal[i]));

                        if mesh.vertex_tangent.exists {
                            tangents.push(
                                convert_vec3(mesh.vertex_tangent[i])
                                    .extend(mesh.vertex_tangent.values_w[i] as f32),
                            );
                        }
                    }
                }

                let mut streams = vec![
                    ufbx::VertexStream::new(&mut positions),
                    ufbx::VertexStream::new(&mut uvs),
                    ufbx::VertexStream::new(&mut normals),
                ];

                if mesh.vertex_tangent.exists {
                    streams.push(ufbx::VertexStream::new(&mut tangents));
                }

                let mut indices = vec![0u32; part.num_triangles * 3];

                let num_vertices = {
                    profiling::scope!("ufbx::generate_indices");
                    ufbx::generate_indices(
                        &mut streams,
                        &mut indices,
                        ufbx::AllocatorOpts::default(),
                    )
                    .expect("expected to generate indices")
                };

                positions.truncate(num_vertices);
                uvs.truncate(num_vertices);
                normals.truncate(num_vertices);

                if mesh.vertex_tangent.exists {
                    tangents.truncate(num_vertices);
                }

                world::Mesh::new(
                    self.gpu,
                    &indices,
                    &positions,
                    &uvs,
                    &normals,
                    if mesh.vertex_tangent.exists {
                        Some(&tangents)
                    } else {
                        None
                    },
                )
            })
    }

    fn get_material(&mut self, mat: &ufbx::Material) -> world::Material {
        let mut material = world::Material::default();

        if mat.pbr.base_color.has_value {
            material.albedo_factor = convert_vec4(mat.pbr.base_color.value_vec4);
            material.albedo_texture = self.get_texture(&mat.pbr.base_color.texture, true);
        }

        if mat.pbr.metalness.has_value {
            material.metallic_factor = mat.pbr.metalness.value_vec4.x as f32;
        }

        if mat.pbr.roughness.has_value {
            material.roughness_factor = mat.pbr.roughness.value_vec4.x as f32;
        }

        if mat.pbr.metalness.has_value || mat.pbr.roughness.has_value {
            material.metallic_roughness_texture = self.get_metalness_roughness_texture(
                &mat.pbr.metalness.texture,
                &mat.pbr.roughness.texture,
            );
        }

        if mat.pbr.emission_color.has_value {
            material.emissive_factor = convert_vec4(mat.pbr.emission_color.value_vec4).xyz();
            material.emissive_texture = self.get_texture(&mat.pbr.emission_color.texture, true);
        }

        if mat.pbr.specular_factor.has_value {
            material.specular_factor = mat.pbr.specular_factor.value_vec4.x as f32;
            material.specular_texture = self.get_texture(&mat.pbr.specular_factor.texture, false);
        }

        if mat.pbr.specular_color.has_value {
            material.specular_color_factor = convert_vec4(mat.pbr.specular_color.value_vec4).xyz();
            material.specular_color_texture =
                self.get_texture(&mat.pbr.specular_color.texture, true);
        }

        if mat.pbr.coat_factor.has_value {
            material.clearcoat_factor = mat.pbr.coat_factor.value_vec4.x as f32;
            material.clearcoat_texture = self.get_texture(&mat.pbr.coat_factor.texture, false);
        }

        if mat.pbr.coat_roughness.has_value {
            material.clearcoat_roughness_factor = mat.pbr.coat_roughness.value_vec4.x as f32;
            material.clearcoat_roughness_texture =
                self.get_texture(&mat.pbr.coat_roughness.texture, false);
        }

        if mat.pbr.normal_map.has_value {
            material.normal_texture = self.get_texture(&mat.pbr.normal_map.texture, false);
        }

        material
    }

    fn get_metalness_roughness_texture(
        &mut self,
        metalness: &Option<ufbx::Ref<ufbx::Texture>>,
        roughness: &Option<ufbx::Ref<ufbx::Texture>>,
    ) -> Option<(Arc<ImageView>, Arc<Sampler>)> {
        println!("{}, {}", metalness.is_some(), roughness.is_some());
        let tex = match metalness {
            Some(tex) => tex,
            None => match roughness {
                Some(tex) => tex,
                None => return None,
            },
        };

        let metalness = metalness.as_ref().map(move |tex| read_image(&tex.content));
        let roughness = roughness.as_ref().map(move |tex| read_image(&tex.content));

        if let Some(metalness) = &metalness
            && let Some(roughness) = &roughness
        {
            assert_eq!(metalness.dimensions(), roughness.dimensions());
        }

        let size = match &metalness {
            Some(image) => uvec2(image.width(), image.height()),
            None => {
                let image = roughness.as_ref().unwrap();
                uvec2(image.width(), image.height())
            }
        };

        let pixels = vec![U8Vec4::ZERO; size.element_product() as usize];

        let image = self.gpu.create_sampled_filled_image(
            size,
            Format::R8G8B8A8_UNORM,
            bytemuck::cast_slice(&pixels),
        );

        let sampler = Sampler::new(
            self.gpu.device.clone(),
            SamplerCreateInfo {
                min_filter: Filter::Linear,
                mag_filter: Filter::Linear,
                address_mode: [
                    convert_wrap(tex.wrap_u),
                    convert_wrap(tex.wrap_v),
                    SamplerAddressMode::Repeat,
                ],
                lod: 0.0..=1.0,
                ..SamplerCreateInfo::simple_repeat_linear_no_mipmap()
            },
        )
        .unwrap();

        Some((image, sampler))
    }

    fn get_texture(
        &mut self,
        tex: &Option<ufbx::Ref<ufbx::Texture>>,
        srgb: bool,
    ) -> Option<(Arc<ImageView>, Arc<Sampler>)> {
        match tex {
            Some(tex) => {
                let data = read_image(&tex.content);

                let format = convert_format(data.color());

                let image = self.gpu.create_sampled_filled_image(
                    uvec2(data.width(), data.height()),
                    if srgb { to_srgb(format) } else { format },
                    data.as_bytes(),
                );

                let sampler = Sampler::new(
                    self.gpu.device.clone(),
                    SamplerCreateInfo {
                        min_filter: Filter::Linear,
                        mag_filter: Filter::Linear,
                        address_mode: [
                            convert_wrap(tex.wrap_u),
                            convert_wrap(tex.wrap_v),
                            SamplerAddressMode::Repeat,
                        ],
                        lod: 0.0..=1.0,
                        ..SamplerCreateInfo::simple_repeat_linear_no_mipmap()
                    },
                )
                .unwrap();

                Some((image, sampler))
            }
            None => None,
        }
    }
}

#[profiling::function]
pub fn load(path: impl AsRef<Path>, gpu: &Gpu, world: &mut World) -> Result<(), String> {
    let opts = ufbx::LoadOpts {
        target_axes: ufbx::CoordinateAxes::right_handed_y_up(),
        target_camera_axes: ufbx::CoordinateAxes::right_handed_y_up(),
        target_light_axes: ufbx::CoordinateAxes::right_handed_y_up(),
        target_unit_meters: 1.0,
        space_conversion: ufbx::SpaceConversion::AdjustTransforms,
        generate_missing_normals: true,
        retain_vertex_attrib_w: true,
        ..Default::default()
    };

    let scene = match ufbx::load_file(path.as_ref().to_str().unwrap(), opts) {
        Ok(scene) => scene,
        Err(e) => return Err(String::from(e.info())),
    };

    let mut loader = ModelLoader {
        gpu,
        world,
        meshes: HashMap::new(),
    };

    for node in &scene.nodes {
        loader.load_node(node);
    }

    Ok(())
}

#[profiling::function]
fn read_image(content: &ufbx::Blob) -> DynamicImage {
    let mut data = ImageReader::new(Cursor::new(&**content))
        .with_guessed_format()
        .unwrap()
        .decode()
        .unwrap();

    data.apply_orientation(image::metadata::Orientation::FlipVertical);

    data
}

fn convert_vec2(vec: ufbx::Vec2) -> Vec2 {
    vec2(vec.x as f32, vec.y as f32)
}

fn convert_vec3(vec: ufbx::Vec3) -> Vec3 {
    vec3(vec.x as f32, vec.y as f32, vec.z as f32)
}

fn convert_vec4(vec: ufbx::Vec4) -> Vec4 {
    vec4(vec.x as f32, vec.y as f32, vec.z as f32, vec.w as f32)
}

fn convert_matrix(mat: ufbx::Matrix) -> Mat4 {
    Mat4 {
        x_axis: vec4(mat.m00 as f32, mat.m10 as f32, mat.m20 as f32, 0.0),
        y_axis: vec4(mat.m01 as f32, mat.m11 as f32, mat.m21 as f32, 0.0),
        z_axis: vec4(mat.m02 as f32, mat.m12 as f32, mat.m22 as f32, 0.0),
        w_axis: vec4(mat.m03 as f32, mat.m13 as f32, mat.m23 as f32, 0.0),
    }
}

fn convert_wrap(wrap: ufbx::WrapMode) -> SamplerAddressMode {
    match wrap {
        ufbx::WrapMode::Repeat => SamplerAddressMode::Repeat,
        ufbx::WrapMode::Clamp => SamplerAddressMode::ClampToBorder,
    }
}

fn convert_format(color: ColorType) -> Format {
    match color {
        ColorType::L8 => Format::R8_UNORM,
        ColorType::La8 => Format::R8G8_UNORM,
        ColorType::Rgb8 => Format::R8G8B8_UNORM,
        ColorType::Rgba8 => Format::R8G8B8A8_UNORM,
        ColorType::L16 => Format::R16_UNORM,
        ColorType::La16 => Format::R16G16_UNORM,
        ColorType::Rgb16 => Format::R16G16B16_UNORM,
        ColorType::Rgba16 => Format::R16G16B16A16_UNORM,
        ColorType::Rgb32F => Format::R32G32B32_SFLOAT,
        ColorType::Rgba32F => Format::R32G32B32A32_SFLOAT,
        _ => unimplemented!(),
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
