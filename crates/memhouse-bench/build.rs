// SPDX-License-Identifier: Apache-2.0
//! The language test sets and Memory Format vectors this crate embeds are reached through
//! `languages` and `memory-format`, symbolic links into the repository (in a published crate:
//! the directories themselves). A checkout made
//! without symbolic links (`core.symlinks=false`, the default of Git for Windows) has a small
//! text file there instead, and every `include_str!` would fail with an error about a path.
//! This says what is wrong and what to do.

const LINKS: &[(&str, &str)] = &[("languages", "tests/en.yaml"), ("memory-format", "vectors/v2-full.jsonl")];

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=languages");
    println!("cargo:rerun-if-changed=memory-format");
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
