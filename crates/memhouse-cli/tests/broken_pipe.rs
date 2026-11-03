// SPDX-License-Identifier: Apache-2.0
//! A reader that stops early (`| head`, `| grep -q`) must not make the CLI panic.

use std::process::{Command, Stdio};

#[test]
fn a_closed_stdout_pipe_exits_quietly() {
    // `openapi` needs no database and prints more than a pipe buffer holds, so the write meets the
    // closed pipe whichever side gets there first.
    let mut child = Command::new(env!("CARGO_BIN_EXE_memhouse"))
        .arg("openapi")
        .env("MEMHOUSE_HOME", std::env::temp_dir().join("memhouse-broken-pipe-test"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start memhouse");
    drop(child.stdout.take());
    let out = child.wait_with_output().expect("wait for memhouse");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "status {:?}, stderr: {stderr}", out.status);
    assert!(!stderr.contains("panicked"), "stderr: {stderr}");
}
