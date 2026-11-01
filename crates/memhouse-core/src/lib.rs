//! MemHouse core: the memory engine shared by every profile, transport and adapter.

pub mod config;
pub mod engine;
pub mod enrich;
pub mod gate;
pub mod query;
pub mod templates;
pub mod traits;
pub mod types;

pub use config::Config;
pub use engine::Engine;
pub use traits::{ChatModel, EmbedKind, Embedder, Reranker, Store};
pub use types::*;
