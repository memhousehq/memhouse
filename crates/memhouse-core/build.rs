// SPDX-License-Identifier: Apache-2.0
//! The language packs this crate embeds are reached through `languages`, a symbolic link to
//! the repository's `languages/` (in a published crate: the directory itself). A checkout made
//! without symbolic links (`core.symlinks=false`, the default of Git for Windows) has a small
//! text file there instead, and every `include_str!` would fail with an error about a path.
//! This says what is wrong and what to do.

const LINKS: &[(&str, &str)] = &[("languages", "en.toml")];

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=languages");
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    for (link, file) in LINKS {
        if !dir.join(link).join(file).is_file() {
            eprintln!(
                "error: {}/{link} is not a directory holding {file}.\n\
                 It is a symbolic link into the repository, and this checkout has none: git wrote it as a plain file.\n\
                 Clone on a filesystem with symbolic links and `git config core.symlinks true` (on Windows: Developer Mode,\n\
                 then `git clone -c core.symlinks=true`), or build inside WSL or a container. See docs/development.md, Build.",
                dir.display()
            );
            std::process::exit(1);
        }
    }
}
