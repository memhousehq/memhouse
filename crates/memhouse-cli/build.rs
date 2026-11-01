// SPDX-License-Identifier: Apache-2.0
//! On macOS, ONNX Runtime's CoreML code uses `@available`, which needs clang's runtime builtins
//! (`___isPlatformVersionAtLeast`). rustc links with `-nodefaultlibs`, so pass the archive to the
//! linker. Link args only apply to this package's own binaries (examples, tests); `memhouse-cli`
//! has the same build script for the `memhouse` binary.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let Ok(out) = std::process::Command::new("clang").arg("--print-runtime-dir").output() else { return };
    let lib = std::path::Path::new(String::from_utf8_lossy(&out.stdout).trim()).join("libclang_rt.osx.a");
    if lib.exists() {
        println!("cargo:rustc-link-arg={}", lib.display());
    }
}
