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
    /// `None` once `close()` has finished. While it runs the deployment is still here, so
    /// that a second `close()` on another thread waits for the same shutdown.
    open: Mutex<Option<Arc<Open>>>,
}

/// An open deployment and the runtime it runs on. `close()` and each running request hold
/// one reference; the last to let go ends the runtime and its threads, so a closed `Lite`
/// that the program still refers to keeps no native thread.
struct Open {
    // Declared first, so dropped first: the store closes while its runtime is still there.
    embedded: Embedded,
    /// The engine's workers and every request run on this runtime.
    runtime: tokio::runtime::Runtime,
}

impl Lite {
    fn current(&self) -> Option<Arc<Open>> {
        self.open.lock().unwrap_or_else(|e| e.into_inner()).clone()
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
        Ok(Lite { open: Mutex::new(Some(Arc::new(Open { embedded, runtime }))) })
    }

    /// One request to the REST API, in process. Returns `(status, body)`.
    #[pyo3(signature = (method, path, body=None, headers=None))]
    fn request(&self, py: Python<'_>, method: &str, path: &str, body: Option<&str>, headers: Option<HashMap<String, String>>) -> PyResult<(u16, String)> {
        let open = self.current().ok_or_else(|| PyRuntimeError::new_err("this Lite is closed"))?;
        let headers: Vec<(String, String)> = headers.unwrap_or_default().into_iter().collect();
        // The GIL is released while the request runs, and while the runtime ends if this was
        // the last reference to a deployment closed meanwhile.
        let (status, bytes) = py
            .detach(move || {
                let answer = open.runtime.block_on(open.embedded.request(method, path, &headers, body.map(str::as_bytes)));
                drop(open);
                answer
            })
            .map_err(runtime_error)?;
        Ok((status, String::from_utf8_lossy(&bytes).into_owned()))
    }

    /// Stop the workers, release the database file and end the runtime's threads. Safe to
    /// call more than once: every call, also one made on another thread while this one is
    /// still closing, returns when the workers have stopped.
    fn close(&self, py: Python<'_>) {
        // The deployment stays in its place until the shutdown is over: a call that arrives
        // meanwhile finds it and waits in `shutdown` for the same workers.
        let Some(open) = self.current() else { return };
        py.detach(move || {
            open.runtime.block_on(open.embedded.shutdown());
            self.open.lock().unwrap_or_else(|e| e.into_inner()).take();
            // The runtime ends here, or when the last request still running on another
            // thread returns.
            drop(open);
        });
    }

    #[getter]
    fn closed(&self) -> bool {
        self.current().is_none_or(|open| open.embedded.is_closed())
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
