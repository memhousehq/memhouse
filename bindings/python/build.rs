// SPDX-License-Identifier: Apache-2.0
//! An extension module does not link libpython: its symbols come from the interpreter that
//! loads it. On macOS the linker has to be told so (`-undefined dynamic_lookup`); elsewhere
//! this prints nothing. With it, a plain `cargo build` of the workspace links this crate too.

fn main() {
    pyo3_build_config::add_extension_module_link_args();
}
