// SPDX-License-Identifier: Apache-2.0
//! `memhouse_lite`: MemHouse Lite inside a Python process (TR-LT-01).
//!
//! The module does not re-expose the engine. It embeds the router the server runs and sends
//! requests to it in process ([`memhouse_server::Embedded`]), so Python gets the REST API as it
//! is, with authentication, the access check, the write gate and the audit trail unchanged.

use memhouse_server::{embedded_config, Embedded};
use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::prelude::*;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// One embedded Lite deployment. See `memhouse_lite/_lite.pyi` for the Python signatures.
#[pyclass(module = "memhouse_lite", frozen)]
struct Lite {
    /// The engine's workers and every request run on this runtime.
    runtime: tokio::runtime::Runtime,
    /// `None` once closed.
    embedded: Mutex<Option<Arc<Embedded>>>,
}

impl Lite {
    fn embedded(&self) -> PyResult<Arc<Embedded>> {
        self.embedded.lock().unwrap_or_else(|e| e.into_inner()).clone().ok_or_else(|| PyRuntimeError::new_err("this Lite is closed"))
    }
}

fn runtime_error(e: impl std::fmt::Display) -> PyErr {
    PyRuntimeError::new_err(format!("{e:#}"))
}

#[pymethods]
impl Lite {
    #[new]
    #[pyo3(signature = (path=None, config=None))]
    fn new(py: Python<'_>, path: Option<PathBuf>, config: Option<PathBuf>) -> PyResult<Lite> {
        let cfg = embedded_config(path.as_deref(), config.as_deref()).map_err(|e| PyValueError::new_err(format!("{e:#}")))?;
        let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("memhouse-lite").build().map_err(runtime_error)?;
        // Opening loads the models and migrates the file: other Python threads run meanwhile.
        let embedded = py.detach(|| runtime.block_on(Embedded::open(cfg))).map_err(runtime_error)?;
        Ok(Lite { runtime, embedded: Mutex::new(Some(Arc::new(embedded))) })
    }

    /// One request to the REST API, in process. Returns `(status, body)`.
    #[pyo3(signature = (method, path, body=None, headers=None))]
    fn request(&self, py: Python<'_>, method: &str, path: &str, body: Option<&str>, headers: Option<HashMap<String, String>>) -> PyResult<(u16, String)> {
        let embedded = self.embedded()?;
        let headers: Vec<(String, String)> = headers.unwrap_or_default().into_iter().collect();
        // The GIL is released while the request runs.
        let (status, bytes) = py.detach(|| self.runtime.block_on(embedded.request(method, path, &headers, body.map(str::as_bytes)))).map_err(runtime_error)?;
        Ok((status, String::from_utf8_lossy(&bytes).into_owned()))
    }

    /// Stop the workers and release the database file. Safe to call more than once.
    fn close(&self, py: Python<'_>) {
        let taken = self.embedded.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(embedded) = taken {
            // Dropped here, or when the last request still running on another thread returns.
            py.detach(|| self.runtime.block_on(embedded.shutdown()));
        }
    }

    #[getter]
    fn closed(&self) -> bool {
        self.embedded.lock().unwrap_or_else(|e| e.into_inner()).is_none()
    }

    fn __enter__(slf: Py<Self>) -> Py<Self> {
        slf
    }

    #[pyo3(signature = (_exc_type=None, _exc=None, _traceback=None))]
    fn __exit__(&self, py: Python<'_>, _exc_type: Option<Py<PyAny>>, _exc: Option<Py<PyAny>>, _traceback: Option<Py<PyAny>>) -> bool {
        self.close(py);
        false
    }
}

#[pymodule]
fn _lite(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<Lite>()?;
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    Ok(())
}
