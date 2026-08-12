use std::path::PathBuf;
use std::process::Command;

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        build_apple_speech_sidecar();
    }
    tauri_build::build()
}

fn build_apple_speech_sidecar() {
    let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("manifest dir"));
    let source =
        manifest_dir.join("../../../reference/apple-speech-cli/Sources/AppleSpeechCLI/main.swift");
    let target = std::env::var("TARGET").expect("cargo target");
    let swift_arch = match target.as_str() {
        "aarch64-apple-darwin" => "arm64",
        "x86_64-apple-darwin" => "x86_64",
        other => panic!("Apple Speech sidecar does not support Cargo target {other}"),
    };
    let binaries = manifest_dir.join("binaries");
    std::fs::create_dir_all(&binaries).expect("create sidecar directory");
    let output = binaries.join(format!("apple-speech-cli-{target}"));
    let module_cache = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo output directory"))
        .join("swift-module-cache");
    std::fs::create_dir_all(&module_cache).expect("create Swift module cache");

    println!("cargo:rerun-if-changed={}", source.display());
    let result = Command::new("xcrun")
        .env("CLANG_MODULE_CACHE_PATH", &module_cache)
        .args([
            "swiftc",
            "-parse-as-library",
            "-O",
            "-target",
            &format!("{swift_arch}-apple-macosx26.0"),
        ])
        .arg(&source)
        .arg("-o")
        .arg(&output)
        .output()
        .expect("Xcode 26 is required to build the Apple Speech sidecar");
    if !result.status.success() {
        panic!(
            "Apple Speech sidecar build failed:\n{}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
}
