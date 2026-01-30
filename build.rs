use std::{env, fs, process::Command};

fn main() {
    compile_shader("ray");
}

fn compile_shader(name: &str) {
    let path = format!("shaders/{}.slang", name);

    // Get all included files and rerun script
    {
        let out = Command::new("slangc")
            .arg("-output-includes")
            .arg(&path)
            .output()
            .unwrap();

        if !out.status.success() {
            panic!(
                "Failed to compile {}\n{}",
                &path,
                String::from_utf8(out.stderr).unwrap()
            );
        }

        String::from_utf8(out.stderr)
            .unwrap()
            .lines()
            .filter_map(move |line| {
                if let Some(start) = line.find("'")
                    && let Some(end) = line.rfind("'")
                {
                    Some(&line[start + 1..end])
                } else {
                    println!("cargo::error={}", line);
                    None
                }
            })
            .for_each(move |file| {
                println!("cargo::rerun-if-changed={}", file);
            });
    }

    // Compile
    {
        let out_dir = format!("{}/shaders", env::var("OUT_DIR").unwrap());
        fs::create_dir_all(&out_dir).unwrap();

        let out = Command::new("slangc")
            .arg("-target")
            .arg("spirv")
            .arg("-preserve-params")
            .arg("-o")
            .arg(format!("{}/{}.spv", out_dir, name))
            .arg(&path)
            .output()
            .unwrap();

        if !out.status.success() {
            panic!(
                "Failed to compile {}\n{}",
                &path,
                String::from_utf8(out.stderr).unwrap()
            );
        }
    }
}
