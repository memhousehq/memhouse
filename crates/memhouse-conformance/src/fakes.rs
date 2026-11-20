// SPDX-License-Identifier: Apache-2.0
//! Deterministic stand-ins the kits use around the adapter under test, and that an adapter's
//! own tests can use: an embedder and a fact extractor that need no model.

use memhouse_core::types::LlmUsage;
use memhouse_core::{ChatModel, EmbedKind, Embedder};

/// Hashed bag of words: texts that share words are close, and the same text always gives the
/// same unit vector.
pub struct HashEmbedder {
    pub id: String,
    pub dim: usize,
}

impl HashEmbedder {
    pub fn new(dim: usize) -> HashEmbedder {
        HashEmbedder { id: format!("conformance:hash-{dim}"), dim }
    }
}

#[async_trait::async_trait]
impl Embedder for HashEmbedder {
    fn id(&self) -> &str {
        &self.id
    }
    fn dim(&self) -> usize {
        self.dim
    }
    async fn embed(&self, texts: &[String], _kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>> {
        Ok(texts
            .iter()
            .map(|t| {
                let mut v = vec![0f32; self.dim];
                for w in t.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() > 2) {
                    let h = memhouse_core::engine::content_hash(w);
                    v[usize::from_str_radix(&h[..8], 16).unwrap_or(0) % self.dim] += 1.0;
                }
                let n = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-6);
                v.iter().map(|x| x / n).collect()
            })
            .collect())
    }
}

/// An extractor that repeats each round of the conversation as one fact citing that round.
pub struct EchoExtractor;

#[async_trait::async_trait]
impl ChatModel for EchoExtractor {
    fn id(&self) -> String {
        "conformance:echo".into()
    }
    async fn chat(&self, _system: &str, user: &str) -> anyhow::Result<(String, LlmUsage)> {
        let conversation = user.split("Conversation:\n").nth(1).unwrap_or("");
        let facts: Vec<serde_json::Value> = conversation
            .split("[round ")
            .skip(1)
            .filter_map(|part| {
                let (n, text) = part.split_once("]\n")?;
                let text = text.trim();
                let text = text.split_once(": ").filter(|(role, _)| !role.contains(' ')).map(|(_, t)| t).unwrap_or(text);
                Some(serde_json::json!({ "text": text, "rounds": [n.trim().parse::<u32>().ok()?] }))
            })
            .collect();
        Ok((serde_json::json!({ "facts": facts }).to_string(), LlmUsage::default()))
    }
}
