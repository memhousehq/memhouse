// SPDX-License-Identifier: Apache-2.0
//! Kits for the model adapters: embedder, reranker, chat model.

use crate::{unless, Report};
use memhouse_core::{ChatModel, EmbedKind, Embedder, Reranker};

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let n = |v: &[f32]| v.iter().map(|x| x * x).sum::<f32>().sqrt();
    dot / (n(a) * n(b)).max(1e-9)
}

const TEXTS: &[&str] =
    &["The user adopted a cat named Miso in March.", "A cat called Miso was adopted by the user in March.", "The quarterly invoice for Acme is due on the last Friday."];

/// The embedder contract: vectors of the declared size, finite and not zero; one per text, in
/// order; the same text gives the same vector, alone or in a batch; a paraphrase is closer than
/// an unrelated text; no text, no vectors.
pub async fn run_embedder_kit(e: &dyn Embedder) -> Report {
    let mut r = Report::new("embedder", e.id());
    let texts: Vec<String> = TEXTS.iter().map(|t| t.to_string()).collect();
    r.check("declares_identity", "a non-empty id and a size above zero", unless(!e.id().trim().is_empty() && e.dim() > 0, || format!("id {:?}, dim {}", e.id(), e.dim())));
    let batch = e.embed(&texts, EmbedKind::Passage).await;
    let vectors = match batch {
        Ok(v) => v,
        Err(err) => {
            r.check("embeds_passages", "three texts give three vectors", Some(format!("the adapter returned an error: {err:#}")));
            return r;
        }
    };
    r.check("embeds_passages", "one vector per text", unless(vectors.len() == texts.len(), || format!("{} vectors for {} texts", vectors.len(), texts.len())));
    if vectors.len() != texts.len() {
        return r;
    }
    r.check(
        "vector_size",
        "every vector has the declared size",
        unless(vectors.iter().all(|v| v.len() == e.dim()), || format!("sizes {:?}, declared {}", vectors.iter().map(|v| v.len()).collect::<Vec<_>>(), e.dim())),
    );
    r.check(
        "vectors_are_finite",
        "every component is a finite number and no vector is all zeros",
        unless(vectors.iter().all(|v| v.iter().all(|x| x.is_finite()) && v.iter().any(|x| *x != 0.0)), || "a vector has a NaN or infinite component, or is all zeros".into()),
    );
    r.outcome(
        "deterministic",
        "the same text gives the same vector on a second call (cosine above 0.9999)",
        async {
            let again = e.embed(&texts[..1], EmbedKind::Passage).await?;
            let c = again.first().map(|v| cosine(v, &vectors[0])).unwrap_or(0.0);
            Ok(unless(c > 0.9999, || format!("cosine {c:.5} between two embeddings of one text")))
        }
        .await,
    );
    r.outcome(
        "batch_equals_single",
        "a text embedded in a batch equals the same text embedded alone, in the batch's order",
        async {
            let alone = e.embed(&texts[2..3], EmbedKind::Passage).await?;
            let c = alone.first().map(|v| cosine(v, &vectors[2])).unwrap_or(0.0);
            Ok(unless(c > 0.999, || format!("cosine {c:.5} between the third text alone and in the batch")))
        }
        .await,
    );
    let (near, far) = (cosine(&vectors[0], &vectors[1]), cosine(&vectors[0], &vectors[2]));
    r.check("similar_texts_are_closer", "a paraphrase is closer than an unrelated text", unless(near > far, || format!("paraphrase cosine {near:.3}, unrelated {far:.3}")));
    r.outcome(
        "embeds_queries",
        "a question about a passage is closer to it than to an unrelated one",
        async {
            let q = e.embed(&["What is the cat called?".to_string()], EmbedKind::Query).await?;
            let Some(q) = q.first().filter(|q| q.len() == e.dim()) else { return Ok(Some("no query vector of the declared size".into())) };
            let (hit, miss) = (cosine(q, &vectors[0]), cosine(q, &vectors[2]));
            Ok(unless(hit > miss, || format!("cosine {hit:.3} to the passage about the cat, {miss:.3} to the one about the invoice")))
        }
        .await,
    );
    r.outcome(
        "empty_input",
        "no texts give no vectors, without an error",
        async {
            let none = e.embed(&[], EmbedKind::Passage).await?;
            Ok(unless(none.is_empty(), || format!("{} vectors for no text", none.len())))
        }
        .await,
    );
    r
}

/// The reranker contract: one finite score per document, in the documents' order; the same
/// input gives the same scores; the document that answers the query scores highest; no
/// documents, no scores.
pub async fn run_reranker_kit(m: &dyn Reranker) -> Report {
    let mut r = Report::new("reranker", m.id());
    let docs: Vec<String> = TEXTS.iter().map(|t| t.to_string()).collect();
    let query = "When is the Acme invoice due?";
    let scores = match m.rerank(query, &docs).await {
        Ok(s) => s,
        Err(e) => {
            r.check("scores_documents", "one score per document", Some(format!("the adapter returned an error: {e:#}")));
            return r;
        }
    };
    r.check("scores_documents", "one score per document", unless(scores.len() == docs.len(), || format!("{} scores for {} documents", scores.len(), docs.len())));
    if scores.len() != docs.len() {
        return r;
    }
    r.check("scores_are_finite", "every score is a finite number", unless(scores.iter().all(|s| s.is_finite()), || format!("scores {scores:?}")));
    r.check(
        "relevant_document_first",
        "the document that answers the query scores highest",
        unless(scores[2] > scores[0] && scores[2] > scores[1], || format!("scores {scores:?}; the third document answers the query")),
    );
    r.outcome(
        "order_follows_the_documents",
        "scores follow the documents when their order changes",
        async {
            let rev: Vec<String> = docs.iter().rev().cloned().collect();
            let s = m.rerank(query, &rev).await?;
            Ok(unless(s.len() == 3 && s[0] > s[1] && s[0] > s[2], || format!("with the documents reversed the scores are {s:?}")))
        }
        .await,
    );
    r.outcome(
        "deterministic",
        "the same input gives the same scores",
        async {
            let again = m.rerank(query, &docs).await?;
            Ok(unless(again.len() == scores.len() && again.iter().zip(&scores).all(|(a, b)| (a - b).abs() < 1e-4), || format!("{scores:?} then {again:?}")))
        }
        .await,
    );
    r.outcome(
        "empty_input",
        "no documents give no scores, without an error",
        async {
            let none = m.rerank(query, &[]).await?;
            Ok(unless(none.is_empty(), || format!("{} scores for no document", none.len())))
        }
        .await,
    );
    r
}

/// The chat-model contract, as enrichment and the write gate use it: a stable non-empty id; an
/// answer that follows a plain instruction; usage that is consistent (a cost is never
/// negative, a reported cost comes with a cost).
pub async fn run_chat_kit(m: &dyn ChatModel) -> Report {
    let mut r = Report::new("chat model", &m.id());
    r.check("declares_identity", "a non-empty id, the same on every call", unless(!m.id().trim().is_empty() && m.id() == m.id(), || format!("id {:?}", m.id())));
    match m.chat("You output JSON only.", "Answer with exactly this JSON object and nothing else: {\"facts\": []}").await {
        Err(e) => r.check("answers", "an answer to a plain instruction", Some(format!("the adapter returned an error: {e:#}"))),
        Ok((text, usage)) => {
            r.check("answers", "an answer to a plain instruction", unless(!text.trim().is_empty(), || "an empty answer".into()));
            let parsed = text.find('{').zip(text.rfind('}')).and_then(|(a, b)| serde_json::from_str::<serde_json::Value>(text.get(a..=b)?).ok());
            r.check(
                "follows_the_output_format",
                "the JSON object asked for, possibly inside a code fence",
                unless(parsed.as_ref().is_some_and(|v| v["facts"].is_array()), || format!("answer {:?}", text.chars().take(120).collect::<String>())),
            );
            r.check(
                "usage_is_consistent",
                "a cost is never negative, and a cost marked as reported by the provider is present",
                unless(usage.cost_usd.is_none_or(|c| c >= 0.0 && c.is_finite()) && (!usage.cost_reported || usage.cost_usd.is_some()), || format!("usage {usage:?}")),
            );
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{EchoExtractor, HashEmbedder};
    use memhouse_core::types::LlmUsage;

    /// An embedder that gives every text the same vector.
    struct Constant;

    #[async_trait::async_trait]
    impl Embedder for Constant {
        fn id(&self) -> &str {
            "broken:constant"
        }
        fn dim(&self) -> usize {
            8
        }
        async fn embed(&self, texts: &[String], _kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>> {
            Ok(texts.iter().map(|_| vec![0.5; 8]).collect())
        }
    }

    /// A reranker that scores by word overlap, and one that answers in reverse order.
    struct Overlap(bool);

    #[async_trait::async_trait]
    impl Reranker for Overlap {
        fn id(&self) -> &str {
            if self.0 {
                "broken:reversed"
            } else {
                "fake:overlap"
            }
        }
        async fn rerank(&self, query: &str, docs: &[String]) -> anyhow::Result<Vec<f32>> {
            let words = |s: &str| s.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() > 2).map(String::from).collect::<std::collections::HashSet<_>>();
            let q = words(query);
            let mut scores: Vec<f32> = docs.iter().map(|d| words(d).intersection(&q).count() as f32).collect();
            if self.0 {
                scores.reverse();
            }
            Ok(scores)
        }
    }

    struct Prose;

    #[async_trait::async_trait]
    impl ChatModel for Prose {
        fn id(&self) -> String {
            "broken:prose".into()
        }
        async fn chat(&self, _system: &str, _user: &str) -> anyhow::Result<(String, LlmUsage)> {
            Ok(("Sure! Here is what I found.".into(), LlmUsage { cost_usd: Some(-1.0), ..Default::default() }))
        }
    }

    #[tokio::test]
    async fn the_stand_in_embedder_passes_and_a_constant_one_fails_with_the_reason() {
        run_embedder_kit(&HashEmbedder::new(64)).await.assert_passed();
        let broken = run_embedder_kit(&Constant).await;
        let failed: Vec<&str> = broken.failures().iter().map(|c| c.name.as_str()).collect();
        assert_eq!(failed, ["similar_texts_are_closer", "embeds_queries"], "{}", broken.failure_text());
        assert!(broken.failure_text().contains(
            "embedder kit, broken:constant: similar_texts_are_closer: expected: a paraphrase is closer than an unrelated text; found: paraphrase cosine 1.000, unrelated 1.000"
        ));
    }

    #[tokio::test]
    async fn a_reranker_must_keep_the_documents_order() {
        run_reranker_kit(&Overlap(false)).await.assert_passed();
        let broken = run_reranker_kit(&Overlap(true)).await;
        assert!(!broken.passed());
        assert!(broken.failures().iter().any(|c| c.name == "relevant_document_first"), "{}", broken.failure_text());
    }

    #[tokio::test]
    async fn a_chat_model_must_follow_the_format() {
        // The echo extractor answers any prompt with a fact list: it follows the format.
        run_chat_kit(&EchoExtractor).await.assert_passed();
        let broken = run_chat_kit(&Prose).await;
        let failed: Vec<&str> = broken.failures().iter().map(|c| c.name.as_str()).collect();
        assert_eq!(failed, ["follows_the_output_format", "usage_is_consistent"]);
    }

    #[test]
    fn a_report_without_checks_did_not_pass() {
        assert!(!Report::new("store", "nothing").passed());
    }
}
