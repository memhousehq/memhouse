// SPDX-License-Identifier: Apache-2.0
//! Error codes of the public API (API v1). The engine returns `anyhow` errors; the ones a client
//! can act on carry a [`Coded`] so every transport reports the same stable code.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Stable machine-readable error codes. Clients branch on these, never on the message text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The request is malformed or fails validation (400).
    InvalidRequest,
    /// Missing or wrong API key (401).
    Unauthorized,
    /// The caller is known but may not do this (403).
    Forbidden,
    /// The record (or route) doesn't exist (404).
    NotFound,
    /// The request conflicts with the stored state: an idempotency key reused for another
    /// request, or a revision of a record that is no longer the current version (409).
    Conflict,
    /// A failure inside MemHouse or its database or models (500).
    Internal,
    /// A dependency is down for now (the intake queue, the database): retry later (503, with
    /// `Retry-After`). Nothing was written (PERF-07).
    Unavailable,
}

impl ErrorCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            ErrorCode::InvalidRequest => "invalid_request",
            ErrorCode::Unauthorized => "unauthorized",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::NotFound => "not_found",
            ErrorCode::Conflict => "conflict",
            ErrorCode::Internal => "internal",
            ErrorCode::Unavailable => "unavailable",
        }
    }

    pub fn http_status(&self) -> u16 {
        match self {
            ErrorCode::InvalidRequest => 400,
            ErrorCode::Unauthorized => 401,
            ErrorCode::Forbidden => 403,
            ErrorCode::NotFound => 404,
            ErrorCode::Conflict => 409,
            ErrorCode::Internal => 500,
            ErrorCode::Unavailable => 503,
        }
    }
}

/// The body of every error response.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ErrorBody {
    /// What went wrong, for people. The wording may change between releases.
    pub error: String,
    pub code: ErrorCode,
}

/// An error with a code, carried inside `anyhow::Error`.
#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub struct Coded {
    pub code: ErrorCode,
    pub message: String,
}

pub fn invalid(message: impl Into<String>) -> anyhow::Error {
    Coded { code: ErrorCode::InvalidRequest, message: message.into() }.into()
}

pub fn not_found(message: impl Into<String>) -> anyhow::Error {
    Coded { code: ErrorCode::NotFound, message: message.into() }.into()
}

pub fn forbidden(message: impl Into<String>) -> anyhow::Error {
    Coded { code: ErrorCode::Forbidden, message: message.into() }.into()
}

pub fn unauthorized(message: impl Into<String>) -> anyhow::Error {
    Coded { code: ErrorCode::Unauthorized, message: message.into() }.into()
}

pub fn conflict(message: impl Into<String>) -> anyhow::Error {
    Coded { code: ErrorCode::Conflict, message: message.into() }.into()
}

pub fn unavailable(message: impl Into<String>) -> anyhow::Error {
    Coded { code: ErrorCode::Unavailable, message: message.into() }.into()
}

/// The code of an error: its [`Coded`] when it has one, else read from validation messages that
/// predate the codes (and from JSON decoding), else `internal`.
pub fn code_of(e: &anyhow::Error) -> ErrorCode {
    if let Some(c) = e.chain().find_map(|c| c.downcast_ref::<Coded>()) {
        return c.code;
    }
    if e.chain().any(|c| c.downcast_ref::<serde_json::Error>().is_some()) {
        return ErrorCode::InvalidRequest;
    }
    let msg = format!("{e:#}");
    if msg.contains("not found") {
        ErrorCode::NotFound
    } else if msg.contains("required") || msg.contains("limit is") || msg.contains("empty") || msg.contains("expected") {
        ErrorCode::InvalidRequest
    } else {
        ErrorCode::Internal
    }
}

pub fn body_of(e: &anyhow::Error) -> ErrorBody {
    ErrorBody { error: format!("{e:#}"), code: code_of(e) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_survive_context() {
        let e = not_found("memory x not found").context("revise");
        assert_eq!(code_of(&e), ErrorCode::NotFound);
        assert_eq!(code_of(&anyhow::anyhow!("content is empty")), ErrorCode::InvalidRequest);
        assert_eq!(code_of(&anyhow::anyhow!("connection refused")), ErrorCode::Internal);
        assert_eq!(body_of(&conflict("key reused")).code.as_str(), "conflict");
    }
}
