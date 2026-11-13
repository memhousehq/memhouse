// SPDX-License-Identifier: Apache-2.0
//! MemHouse core: the memory engine shared by every profile, transport and adapter.

pub mod access;
pub mod caller;
pub mod classify;
pub mod config;
pub mod engine;
pub mod enrich;
pub mod error;
pub mod explain;
pub mod format;
pub mod gate;
pub mod identity;
pub mod intake;
pub mod metrics;
pub mod policy;
pub mod preference;
pub mod promote;
pub mod query;
pub mod reembed;
pub mod sharing;
pub mod templates;
pub mod traits;
pub mod types;
pub mod working;

pub use config::Config;
pub use engine::Engine;
pub use traits::{ChatModel, Classifier, EmbedKind, Embedder, IntakeQueue, PiiDetector, Reranker, Store};
pub use types::*;
