//! `memhouse up` / `down`: run a local Postgres with pgvector in Docker, managed for the user.

use anyhow::Context;
use memhouse_core::Config;
use std::process::Command;
use std::time::Duration;

pub const IMAGE: &str = "pgvector/pgvector:pg17";
pub const CONTAINER: &str = "memhouse-pg";
pub const VOLUME: &str = "memhouse-pgdata";

fn docker(args: &[&str]) -> anyhow::Result<(bool, String)> {
    let out = Command::new("docker")
        .args(args)
        .output()
        .context("Docker is not installed or not on PATH. Install Docker Desktop, or point MemHouse at your own Postgres with `memhouse init --database-url ...`")?;
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    Ok((out.status.success(), text.trim().to_string()))
}

pub fn docker_available() -> bool {
    docker(&["info", "--format", "{{.ServerVersion}}"]).map(|(ok, _)| ok).unwrap_or(false)
}

pub fn container_state() -> Option<String> {
    match docker(&["inspect", "-f", "{{.State.Status}}", CONTAINER]) {
        Ok((true, s)) => Some(s),
        _ => None,
    }
}

/// Start (or create) the managed container. Returns the database URL.
pub fn start(port: u16, password: &str) -> anyhow::Result<String> {
    if !docker_available() {
        anyhow::bail!("Docker is not running. Start Docker Desktop (or the docker daemon) and run `memhouse up` again.");
    }
    match container_state().as_deref() {
        Some("running") => {}
        Some(_) => {
            let (ok, out) = docker(&["start", CONTAINER])?;
            if !ok {
                anyhow::bail!("could not start container {CONTAINER}: {out}");
            }
        }
        None => {
            eprintln!("Starting Postgres 17 + pgvector in Docker ({IMAGE}) on 127.0.0.1:{port} ...");
            let port_map = format!("127.0.0.1:{port}:5432");
            let pw = format!("POSTGRES_PASSWORD={password}");
            let vol = format!("{VOLUME}:/var/lib/postgresql/data");
            let (ok, out) = docker(&[
                "run", "-d", "--name", CONTAINER, "--restart", "unless-stopped",
                "-e", "POSTGRES_USER=memhouse", "-e", &pw, "-e", "POSTGRES_DB=memhouse",
                "-p", &port_map, "-v", &vol,
                "--label", "org.memhouse.managed=true",
                IMAGE,
                "-c", "shared_buffers=256MB", "-c", "work_mem=32MB", "-c", "max_connections=200",
                "-c", "synchronous_commit=on",
            ])?;
            if !ok {
                anyhow::bail!("docker run failed: {out}");
            }
        }
    }
    Ok(format!("postgres://memhouse:{password}@127.0.0.1:{port}/memhouse"))
}

pub async fn wait_ready(url: &str, timeout: Duration) -> anyhow::Result<()> {
    let start = std::time::Instant::now();
    loop {
        match sqlx::postgres::PgPoolOptions::new().max_connections(1).acquire_timeout(Duration::from_secs(2)).connect(url).await {
            Ok(pool) => {
                if sqlx::query("SELECT 1").execute(&pool).await.is_ok() {
                    return Ok(());
                }
            }
            Err(e) if start.elapsed() > timeout => anyhow::bail!("Postgres did not become ready in {timeout:?}: {e}"),
            Err(_) => {}
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

pub fn stop() -> anyhow::Result<()> {
    match container_state() {
        None => {
            eprintln!("No managed container ({CONTAINER}) found.");
            Ok(())
        }
        Some(_) => {
            let (ok, out) = docker(&["stop", CONTAINER])?;
            if !ok {
                anyhow::bail!("docker stop failed: {out}");
            }
            eprintln!("Stopped {CONTAINER}. Your memories are kept in the Docker volume {VOLUME}; `memhouse up` starts it again.");
            Ok(())
        }
    }
}

pub fn managed(cfg: &Config) -> bool {
    cfg.database.container.as_deref() == Some(CONTAINER)
}
