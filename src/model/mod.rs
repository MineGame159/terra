mod fbx;
mod gltf;

use std::path::Path;

use hecs::World;

use crate::gpu::Gpu;

pub fn load(path: impl AsRef<Path>, gpu: &Gpu, world: &mut World) -> Result<(), String> {
    let path = path.as_ref();

    match path.extension() {
        Some(ext) => match ext.to_str() {
            Some("gltf") | Some("glb") => gltf::load(path, gpu, world),
            Some("fbx") => fbx::load(path, gpu, world),
            _ => Err(format!("invalid extension '{}'", ext.display())),
        },
        None => Err(String::from("invalid path to a file")),
    }
}
