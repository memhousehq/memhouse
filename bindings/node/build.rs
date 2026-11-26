// SPDX-License-Identifier: Apache-2.0
//! An addon does not link Node.js: its N-API symbols come from the process that loads it.
//! `napi-build` passes the linker what that needs on each platform, so a plain `cargo build`
//! of the workspace links this crate too.

fn main() {
    napi_build::setup();
}
