//! `memhouse up` / `down`: run a local Postgres with pgvector in Docker, managed for the user.

use anyhow::Context;
use memhouse_core::Config;
use std::process::Command;
use std::time::Duration;

pub const IMAGE: &str = "pgvector/pgvector:pg17";
pub const CONTAINER: &str = "memhouse-pg";

pub fn volume_for(container: &str) -> String {
    if container == CONTAINER {
        "memhouse-pgdata".into()
    } else {
        format!("{container}-data")
    }
}

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

pub fn container_state(name: &str) -> Option<String> {
    match docker(&["inspect", "-f", "{{.State.Status}}", name]) {
        Ok((true, s)) => Some(s),
        _ => None,
    }
}

/// Start (or create) the managed container. Returns the database URL.
pub fn start(name: &str, port: u16, password: &str, fresh: bool) -> anyhow::Result<String> {
    if !docker_available() {
        anyhow::bail!("Docker is not running. Start Docker Desktop (or the docker daemon) and run `memhouse up` again.");
    }
    let existing = container_state(name);
    if fresh && existing.is_some() {
        anyhow::bail!(
            "a container named {name} already exists but this config is new, so its password is unknown. \
             Use the config that created it (MEMHOUSE_HOME), pick another name with `memhouse up --name <name> --port <port>`, \
             or remove it (deletes its data): docker rm -f {name} && docker volume rm {}",
            volume_for(name)
        );
    }
    match existing.as_deref() {
        Some("running") => {}
        Some(_) => {
            let (ok, out) = docker(&["start", name])?;
            if !ok {
                anyhow::bail!("could not start container {name}: {out}");
            }
        }
        None => {
            eprintln!("Starting Postgres 17 + pgvector in Docker ({IMAGE}) on 127.0.0.1:{port} ...");
            let port_map = format!("127.0.0.1:{port}:5432");
            let pw = format!("POSTGRES_PASSWORD={password}");
            let vol = format!("{}:/var/lib/postgresql/data", volume_for(name));
            let (ok, out) = docker(&[
                "run",
                "-d",
                "--name",
                name,
                "--restart",
                "unless-stopped",
                "-e",
                "POSTGRES_USER=memhouse",
                "-e",
                &pw,
                "-e",
                "POSTGRES_DB=memhouse",
                "-p",
                &port_map,
                "-v",
                &vol,
                "--label",
                "org.memhouse.managed=true",
                IMAGE,
                "-c",
                "shared_buffers=256MB",
                "-c",
                "work_mem=32MB",
                "-c",
                "max_connections=200",
                "-c",
                "synchronous_commit=on",
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

pub fn stop(name: &str) -> anyhow::Result<()> {
    match container_state(name) {
        None => {
            eprintln!("No managed container ({name}) found.");
            Ok(())
        }
        Some(_) => {
            let (ok, out) = docker(&["stop", name])?;
            if !ok {
                anyhow::bail!("docker stop failed: {out}");
            }
            eprintln!("Stopped {name}. Your memories are kept in the Docker volume {}; `memhouse up` starts it again.", volume_for(name));
            Ok(())
        }
    }
}

pub fn managed(cfg: &Config) -> Option<&str> {
    cfg.database.container.as_deref()
}
