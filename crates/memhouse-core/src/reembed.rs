// SPDX-License-Identifier: Apache-2.0
//! Re-embedding every stored memory with another model (or passage prefix), in place (TR-MS-04).
//!
//! New vectors are written next to the current ones while the old model keeps serving, then one
//! short transaction checks that nothing is left and switches. A run can be interrupted and
//! resumed, or aborted before the switch without touching the current vectors.

use crate::engine::{content_hash, Engine};
use crate::traits::EmbedKind;
use crate::types::*;
use std::time::Instant;

#[derive(Debug, Clone, serde::Serialize)]
pub struct ReembedReport {
    pub from: EmbeddingIdentity,
    pub to: EmbeddingIdentity,
    /// Records embedded by this run (an interrupted run's records are not counted again).
    pub records: u64,
    pub second_vectors: u64,
    /// Second vectors whose text couldn't be recovered exactly; those records keep one vector.
    pub second_vectors_dropped: u64,
    pub passes: u32,
    pub seconds: f64,
}

pub enum Outcome {
    /// The database already uses the configured embedder.
    Current(EmbeddingIdentity),
    Done(ReembedReport),
}

/// The identity the engine's configuration would write with.
pub fn target(engine: &Engine) -> EmbeddingIdentity {
    EmbeddingIdentity { embedder: engine.embedder.id().to_string(), dim: engine.embedder.dim(), passage_prefix: engine.cfg.embedding.passage_prefix.clone().unwrap_or_default() }
}

/// Recover the user-only text a round's second vector was made from. The round's content is
/// `role: text` lines starting with the user's message; the candidate whose hash (with the
/// passage prefix used then) equals the stored key is the exact text, so nothing is guessed.
pub fn recover_focus(content: &str, alt_hash: &str, prefixes: &[&str]) -> Option<String> {
    let first = content.find(": ")? + 2;
    let body = &content[first..];
    let ends = body.match_indices('\n').map(|(i, _)| i).chain(std::iter::once(body.len()));
    for end in ends {
        let candidate = body[..end].trim();
        for p in prefixes {
            if content_hash(&format!("{p}{candidate}")) == alt_hash {
                return Some(candidate.to_string());
            }
        }
    }
    None
}

/// Re-embed every record with the engine's embedder. `progress(done, total)` is called per batch.
pub async fn run(engine: &Engine, actor: &str, batch: usize, mut progress: impl FnMut(u64, u64)) -> anyhow::Result<Outcome> {
    let start = Instant::now();
    let to = target(engine);
    let (current, pending) = engine.store.embedding_identity().await?;
    let from = current.ok_or_else(|| anyhow::anyhow!("this database has no memories yet (run `memhouse init` first)"))?;
    if let Some(p) = &pending {
        if *p != to {
            anyhow::bail!("an unfinished re-embedding to {p} exists; finish it with that configuration, or run `memhouse reembed --abort`");
        }
    } else if from == to {
        return Ok(Outcome::Current(from));
    }
    let est = engine.store.reembed_estimate().await?;
    engine.store.reembed_begin(&to).await?;
    let total = est.records;
    let mut done = est.done;
    progress(done, total);
    let mut prefixes: Vec<&str> = vec![];
    for p in [from.passage_prefix.as_str(), to.passage_prefix.as_str(), ""] {
        if !prefixes.contains(&p) {
            prefixes.push(p);
        }
    }
    let (mut records, mut seconds, mut dropped) = (0u64, 0u64, 0u64);
    let mut passes = 0;
    loop {
        passes += 1;
        let mut after = None;
        loop {
            let rows = engine.store.reembed_pending(after, batch.max(1)).await?;
            let Some(last) = rows.last() else { break };
            after = Some(last.id);
            let mut texts: Vec<String> = rows.iter().map(|r| format!("{}{}", to.passage_prefix, r.content)).collect();
            let n = texts.len();
            // (row index, new cache key) for rounds whose second vector is rebuilt.
            let mut alts = vec![];
            for (i, r) in rows.iter().enumerate() {
                let Some(h) = &r.alt_hash else { continue };
                match recover_focus(&r.content, h, &prefixes) {
                    Some(f) => {
                        let text = format!("{}{f}", to.passage_prefix);
                        alts.push((i, content_hash(&text)));
                        texts.push(text);
                    }
                    None => dropped += 1,
                }
            }
            let mut vecs = engine.embedder.embed(&texts, EmbedKind::Passage).await?;
            anyhow::ensure!(vecs.len() == texts.len(), "embedder returned {} vectors for {} texts", vecs.len(), texts.len());
            let alt_vecs = vecs.split_off(n);
            let mut out: Vec<ReembedVectors> = rows.iter().zip(vecs).map(|(r, v)| ReembedVectors { id: r.id, embedding: v, alt: None }).collect();
            for ((i, h), v) in alts.into_iter().zip(alt_vecs) {
                out[i].alt = Some((h, v));
                seconds += 1;
            }
            engine.store.reembed_write(&to, &out).await?;
            records += out.len() as u64;
            done += out.len() as u64;
            progress(done, total.max(done));
        }
        // Writers that kept the old model during the pass leave a few records behind; another
        // pass picks them up. The switch itself refuses while anything is pending.
        match engine.store.reembed_cutover(&to).await? {
            None => break,
            Some(left) if passes >= 10 => {
                anyhow::bail!("{left} records keep arriving from writers on the old model; stop them and run `memhouse reembed` again (progress is kept)")
            }
            Some(_) => continue,
        }
    }
    let report = ReembedReport { from, to, records, second_vectors: seconds, second_vectors_dropped: dropped, passes, seconds: start.elapsed().as_secs_f64() };
    engine.store.audit(actor, "embedding.reembed", &engine.cfg.memory.tenant, None, None, serde_json::to_value(&report)?).await?;
    Ok(Outcome::Done(report))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::build_rounds;

    fn msg(role: &str, content: &str) -> Message {
        Message { role: role.into(), content: content.into(), timestamp: None, id: None }
    }

    #[test]
    fn recovers_the_user_text_of_a_round_exactly() {
        let user = "I moved to Lisbon last spring.\nThe rent is lower: about half.";
        let rounds = build_rounds(&[msg("user", user), msg("assistant", "Nice!\nuser: not a real turn"), msg("tool", "ok")], 1200);
        let r = &rounds[0];
        let focus = r.focus.clone().unwrap();
        for prefix in ["", "search_document: "] {
            let h = content_hash(&format!("{prefix}{focus}"));
            assert_eq!(recover_focus(&r.text, &h, &["passage: ", prefix]).as_deref(), Some(focus.as_str()));
        }
        assert_eq!(recover_focus(&r.text, "0000", &[""]), None);
        assert_eq!(recover_focus("no role prefix", "0000", &[""]), None);
    }
}
