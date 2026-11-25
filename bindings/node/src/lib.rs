// SPDX-License-Identifier: Apache-2.0
//! `@memhouse/lite`: MemHouse Lite inside a Node.js process (TR-LT-01).
//!
//! The addon does not re-expose the engine. It embeds the router the server runs and sends
//! requests to it in process ([`memhouse_server::Embedded`]), so JavaScript gets the REST API
//! as it is, with authentication, the access check, the write gate and the audit trail
//! unchanged.

use memhouse_server::{embedded_config, Embedded};
use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

fn error(e: impl std::fmt::Display) -> Error {
    Error::new(Status::GenericFailure, format!("{e:#}"))
}

/// Where the deployment is. Give one of the two, or neither for the installation's own
/// configuration (`MEMHOUSE_CONFIG`, or `config.toml` under `MEMHOUSE_HOME`).
#[napi(object)]
pub struct LiteOptions {
    /// The SQLite file to use (created if missing, with the defaults of the Lite profile).
    pub path: Option<String>,
    /// A `config.toml` to read instead.
    pub config: Option<String>,
}

/// The answer to one request.
#[napi(object)]
pub struct LiteResponse {
    /// The HTTP status the API answered with.
    pub status: u32,
    /// The response body as text (JSON for every API route).
    pub body: String,
}

/// One embedded MemHouse Lite deployment. Create it with `await Lite.open(...)`.
#[napi]
pub struct Lite {
    /// `None` once closed.
    embedded: Mutex<Option<Arc<Embedded>>>,
}

#[napi]
impl Lite {
    /// Open the deployment: load the models, migrate the file, start the background workers.
    #[napi(factory)]
    pub async fn open(options: Option<LiteOptions>) -> Result<Lite> {
        let (path, config) = options.map(|o| (o.path, o.config)).unwrap_or_default();
        let cfg = embedded_config(path.as_deref().map(Path::new), config.as_deref().map(Path::new)).map_err(|e| Error::new(Status::InvalidArg, format!("{e:#}")))?;
        let embedded = Embedded::open(cfg).await.map_err(error)?;
        Ok(Lite { embedded: Mutex::new(Some(Arc::new(embedded))) })
    }

    /// Send one request to the REST API in process. Without an `Authorization` or `x-api-key`
    /// header, it is sent with the deployment's configured bootstrap key. Rejects after
    /// `close()`.
    #[napi]
    pub async fn request(&self, method: String, path: String, body: Option<String>, headers: Option<HashMap<String, String>>) -> Result<LiteResponse> {
        let embedded = self.embedded.lock().unwrap_or_else(|e| e.into_inner()).clone().ok_or_else(|| error("this Lite is closed"))?;
        let headers: Vec<(String, String)> = headers.unwrap_or_default().into_iter().collect();
        let (status, bytes) = embedded.request(&method, &path, &headers, body.as_deref().map(str::as_bytes)).await.map_err(error)?;
        Ok(LiteResponse { status: status.into(), body: String::from_utf8_lossy(&bytes).into_owned() })
    }

    /// Stop the background workers and release the database file. Safe to call more than once.
    #[napi]
    pub async fn close(&self) -> Result<()> {
        let taken = self.embedded.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(embedded) = taken {
            embedded.shutdown().await;
        }
        Ok(())
    }

    /// Whether `close()` was called.
    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.embedded.lock().unwrap_or_else(|e| e.into_inner()).is_none()
    }
}
