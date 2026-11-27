// SPDX-License-Identifier: Apache-2.0
//! Hybrid recall (TR-RQ): FTS5 keyword candidates and exact vector candidates of one subject,
//! fused by weighted reciprocal rank. The filters are the Postgres statement's, clause for clause.

use crate::util::*;
use crate::vector::{from_half, Probe};
use crate::SqliteStore;
use memhouse_core::types::*;
use rusqlite::types::Value;
use rusqlite::{Connection, Statement};
use std::collections::HashMap;

/// The recall filters. `:session` is `access::NOBODY` for a reader that names no session: it
/// sees every session's records as in API 1.4, except working memory, which is session-local
/// (MEM-01). A reader without grants passes an empty `:shared`.
fn filters(no_session: bool) -> String {
    let session =
        if no_session { "AND (m.scope_session IS NULL OR m.kind <> 'working')" } else { "AND (:session IS NULL OR m.scope_session IS NULL OR m.scope_session = :session)" };
    format!(
        r#"
    -- As-of recall also sees versions superseded since; validity below keeps the one true then.
    AND (m.status = 'committed' OR (:as_of IS NOT NULL AND m.status = 'superseded') OR (:candidates AND m.status = 'candidate'))
    AND (:kinds IS NULL OR m.kind IN (SELECT value FROM json_each(:kinds)))
    AND (:tags IS NULL OR EXISTS (SELECT 1 FROM json_each(m.tags) t WHERE t.value IN (SELECT value FROM json_each(:tags))))
    AND NOT EXISTS (SELECT 1 FROM json_each(m.labels) l WHERE l.value IN (SELECT value FROM json_each(:denied)))
    AND m.valid_from <= :valid_at AND (m.valid_to IS NULL OR m.valid_to > :valid_at)
    AND (m.expires_at IS NULL OR m.expires_at > :valid_at)
    AND (:org IS NULL OR m.scope_org IS NULL OR m.scope_org = :org)
    AND (:team IS NULL OR m.scope_team IS NULL OR m.scope_team = :team)
    AND (:agent IS NULL OR m.scope_agent IS NULL OR m.scope_agent = :agent
         OR (m.scope_agent || char(31) || '*') IN (SELECT value FROM json_each(:shared))
         OR (m.scope_agent || char(31) || m.kind) IN (SELECT value FROM json_each(:shared)))
    AND (:user IS NULL OR m.scope_user IS NULL OR m.scope_user = :user)
    {session}
    AND (:as_of IS NULL OR m.occurred_at IS NULL OR m.occurred_at <= :as_of)
    AND (:windows IS NULL OR EXISTS (
      SELECT 1 FROM json_each(:windows) w
      WHERE m.occurred_at >= json_extract(w.value, '$[0]') AND m.occurred_at < json_extract(w.value, '$[1]')))
    -- A record about a file that changed since is left out until it is revalidated (TPL-04).
    AND (:stale OR m.stale_since IS NULL)
"#
    )
}

pub(crate) fn recall_filters(q: &SearchQuery) -> String {
    filters(q.scope.session.as_deref() == Some(memhouse_core::access::NOBODY))
}

fn text(v: &Option<String>) -> Value {
    v.clone().map(Value::Text).unwrap_or(Value::Null)
}

/// The values of a recall's named parameters.
pub(crate) fn recall_params(q: &SearchQuery) -> anyhow::Result<Vec<(&'static str, Value)>> {
    let kinds = q.kinds.as_ref().map(|ks| json(&ks.iter().map(|k| k.as_str()).collect::<Vec<_>>())).transpose()?;
    let windows: Vec<(i64, i64)> = q.windows.iter().map(|w| (us(w.0), us(w.1))).collect();
    Ok(vec![
        (":tenant", Value::Text(q.tenant.clone())),
        (":subject", Value::Text(q.subject.clone())),
        (":kinds", text(&kinds)),
        (":tags", text(&q.tags.as_ref().map(json).transpose()?)),
        (":denied", Value::Text(json(&q.denied_labels)?)),
        (":as_of", q.as_of.map(|t| Value::Integer(us(t))).unwrap_or(Value::Null)),
        (":valid_at", Value::Integer(us(q.valid_at))),
        (":org", text(&q.scope.org)),
        (":team", text(&q.scope.team)),
        (":agent", text(&q.scope.agent)),
        (":user", text(&q.scope.user)),
        (":session", text(&q.scope.session)),
        (":candidates", Value::Integer(q.include_candidates as i64)),
        (":shared", Value::Text(json(&q.shared_agents)?)),
        (":windows", if windows.is_empty() { Value::Null } else { Value::Text(json(&windows)?) }),
        (":stale", Value::Integer(q.include_stale as i64)),
    ])
}

/// Bind the named parameters a statement has (the unfiltered statement has only some).
pub(crate) fn bind(st: &mut Statement, values: &[(&'static str, Value)]) -> anyhow::Result<()> {
    for i in 1..=st.parameter_count() {
        let Some(name) = st.parameter_name(i).map(str::to_string) else { continue };
        let (_, v) = values.iter().find(|(k, _)| *k == name).ok_or_else(|| anyhow::anyhow!("no value for the statement parameter {name}"))?;
        st.raw_bind_parameter(i, v)?;
    }
    Ok(())
}

/// Words Postgres' `english` configuration drops from a query (its snowball stop list): left
/// in, a question would match every record that says "the".
const STOP: &[&str] = &[
    "i",
    "me",
    "my",
    "myself",
    "we",
    "our",
    "ours",
    "ourselves",
    "you",
    "your",
    "yours",
    "yourself",
    "yourselves",
    "he",
    "him",
    "his",
    "himself",
    "she",
    "her",
    "hers",
    "herself",
    "it",
    "its",
    "itself",
    "they",
    "them",
    "their",
    "theirs",
    "themselves",
    "what",
    "which",
    "who",
    "whom",
    "this",
    "that",
    "these",
    "those",
    "am",
    "is",
    "are",
    "was",
    "were",
    "be",
    "been",
    "being",
    "have",
    "has",
    "had",
    "having",
    "do",
    "does",
    "did",
    "doing",
    "a",
    "an",
    "the",
    "and",
    "but",
    "if",
    "or",
    "because",
    "as",
    "until",
    "while",
    "of",
    "at",
    "by",
    "for",
    "with",
    "about",
    "against",
    "between",
    "into",
    "through",
    "during",
    "before",
    "after",
    "above",
    "below",
    "to",
    "from",
    "up",
    "down",
    "in",
    "out",
    "on",
    "off",
    "over",
    "under",
    "again",
    "further",
    "then",
    "once",
    "here",
    "there",
    "when",
    "where",
    "why",
    "how",
    "all",
    "any",
    "both",
    "each",
    "few",
    "more",
    "most",
    "other",
    "some",
    "such",
    "no",
    "nor",
    "not",
    "only",
    "own",
    "same",
    "so",
    "than",
    "too",
    "very",
    "s",
    "t",
    "can",
    "will",
    "just",
    "don",
    "should",
    "now",
];

/// The `MATCH` of a recall: the subject's token, and any of the question's words. Each word is
/// quoted, so nothing in the question can form query syntax. `None` when no word is left.
pub fn match_query(subject_token: &str, question: &str) -> Option<String> {
    let mut terms: Vec<String> =
        question.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() >= 2).map(|w| w.to_lowercase()).filter(|w| !STOP.contains(&w.as_str())).collect();
    terms.sort();
    terms.dedup();
    terms.truncate(64);
    if terms.is_empty() {
        return None;
    }
    Some(format!("stok:\"{subject_token}\" AND content:({})", terms.iter().map(|t| format!("\"{t}\"")).collect::<Vec<_>>().join(" OR ")))
}

/// Score every row of `rows` (columns: id, vector, and with `alt` a second vector) against the
/// probe: the best of a row's vectors counts. Most similar first, ties by id; at most `n`.
pub(crate) fn scan(rows: &mut rusqlite::Rows<'_>, probe: &Probe, alt: bool, n: usize) -> anyhow::Result<Vec<(String, f32)>> {
    let mut scored: Vec<(String, f32)> = vec![];
    while let Some(r) = rows.next()? {
        let Some(blob) = r.get_ref(1)?.as_blob_or_null()? else { continue };
        let mut sim = probe.cosine(blob)?;
        if alt {
            if let Some(blob) = r.get_ref(2)?.as_blob_or_null()? {
                sim = sim.max(probe.cosine(blob)?);
            }
        }
        scored.push((r.get(0)?, sim));
    }
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored.truncate(n);
    Ok(scored)
}

struct Fused {
    score: f64,
    keyword_rank: Option<i32>,
    vector_rank: Option<i32>,
    similarity: Option<f32>,
}

impl SqliteStore {
    /// One probe of a recall. `filtered = false` drops every filter but tenant and subject: the
    /// candidates a recall explanation classifies.
    pub(crate) fn search_in(&self, c: &Connection, q: &SearchQuery, filtered: bool) -> anyhow::Result<Vec<Hit>> {
        let filters = if filtered { recall_filters(q) } else { String::new() };
        let params = recall_params(q)?;
        let use_kw = q.mode != RetrievalMode::Dense;
        let mut fused: HashMap<String, Fused> = HashMap::new();

        // Keyword candidates: only the subject's rows match (the token is part of the MATCH).
        // BM25 ranks them with the statistics of the whole table (document frequencies, average
        // length), as FTS5 keeps them: other subjects' records can change the order, never the set.
        if let Some(m) = match_query(&crate::subject_token(&q.tenant, &q.subject), &q.text).filter(|_| use_kw) {
            let sql = format!(
                "SELECT m.id FROM mh_memory_fts f JOIN mh_memory m ON m.rid = f.rowid \
                 WHERE mh_memory_fts MATCH :match AND m.tenant = :tenant AND m.subject = :subject {filters} \
                 ORDER BY bm25(mh_memory_fts, 0.0, 1.0), m.id LIMIT :per"
            );
            let mut st = c.prepare_cached(&sql)?;
            let mut values = params.clone();
            values.push((":match", Value::Text(m)));
            values.push((":per", Value::Integer(q.per_retriever as i64)));
            bind(&mut st, &values)?;
            let mut rows = st.raw_query();
            let mut rank = 0;
            while let Some(r) = rows.next()? {
                rank += 1;
                fused.insert(r.get(0)?, Fused { score: q.keyword_weight as f64 / (q.rrf_k as f64 + rank as f64), keyword_rank: Some(rank), vector_rank: None, similarity: None });
            }
        }

        // Vector candidates: every vector of the subject that passes the filters, scored exactly.
        if let Some(embedding) = q.embedding.as_ref().filter(|_| q.mode != RetrievalMode::Keyword) {
            let probe = Probe::new(embedding);
            let from = format!("FROM mh_memory m WHERE m.tenant = :tenant AND m.subject = :subject AND m.embedding IS NOT NULL {filters}");
            let near = match self.prefilter {
                Some((min_rows, depth)) => self.prefiltered(c, &from, &params, &probe, min_rows, depth, q.per_retriever)?,
                None => None,
            };
            let near = match near {
                Some(n) => n,
                None => {
                    let mut st = c.prepare_cached(&format!("SELECT m.id, m.embedding, m.embedding_alt {from}"))?;
                    bind(&mut st, &params)?;
                    let mut found = st.raw_query();
                    let near = scan(&mut found, &probe, true, q.per_retriever)?;
                    drop(found);
                    near
                }
            };
            for (i, (id, sim)) in near.into_iter().enumerate() {
                let rank = i as i32 + 1;
                let s = q.vector_weight as f64 / (q.rrf_k as f64 + rank as f64);
                let f = fused.entry(id).or_insert(Fused { score: 0.0, keyword_rank: None, vector_rank: None, similarity: None });
                f.score += s;
                f.vector_rank = Some(rank);
                f.similarity = Some(sim);
            }
        }

        // Best fused score first, then the more similar, then the id (a stable order).
        let mut top: Vec<(String, Fused)> = fused.into_iter().collect();
        top.sort_by(|a, b| {
            let sim = |f: &Fused| f.similarity.unwrap_or(f32::NEG_INFINITY);
            b.1.score.total_cmp(&a.1.score).then_with(|| sim(&b.1).total_cmp(&sim(&a.1))).then_with(|| a.0.cmp(&b.0))
        });
        top.truncate(q.limit);
        if top.is_empty() {
            return Ok(vec![]);
        }

        // Only the top rows are read in full, each by its id, inside the subject (TR-RQ-01).
        let ids = serde_json::Value::from(top.iter().map(|(id, _)| id.clone()).collect::<Vec<_>>()).to_string();
        let emb = if q.with_vectors { "m.embedding" } else { "NULL" };
        let sql = format!("SELECT {COLS}, {emb} AS emb FROM mh_memory m WHERE m.tenant = ?1 AND m.subject = ?2 AND m.id IN (SELECT value FROM json_each(?3))");
        let mut found: HashMap<String, (Memory, Option<Vec<f32>>)> = HashMap::new();
        for (m, e) in rows(c, &sql, rusqlite::params![q.tenant, q.subject, ids], |r| Ok((memory_of(r)?, r.get_ref("emb")?.as_blob_or_null()?.map(from_half))))? {
            found.insert(m.id.to_string(), (m, e));
        }
        Ok(top
            .into_iter()
            .filter_map(|(id, f)| {
                let (memory, embedding) = found.remove(&id)?;
                Some(Hit {
                    memory,
                    score: f.score as f32,
                    keyword_rank: f.keyword_rank,
                    vector_rank: f.vector_rank,
                    similarity: f.similarity,
                    rerank_score: None,
                    exact: false,
                    working: false,
                    embedding,
                    features: None,
                })
            })
            .collect())
    }

    /// The optional prefilter of ADR 0003: the `depth` rows nearest by sign bits, rescored
    /// exactly. `None` when the subject is small enough for the full scan.
    #[allow(clippy::too_many_arguments)]
    fn prefiltered(
        &self,
        c: &Connection,
        from: &str,
        params: &[(&'static str, Value)],
        probe: &Probe,
        min_rows: usize,
        depth: usize,
        n: usize,
    ) -> anyhow::Result<Option<Vec<(String, f32)>>> {
        let mut st = c.prepare_cached(&format!("SELECT m.rid, m.embedding_bits, m.embedding_alt_bits {from}"))?;
        bind(&mut st, params)?;
        let mut rows = st.raw_query();
        let mut near: Vec<(u32, i64)> = vec![];
        while let Some(r) = rows.next()? {
            let mut d = r.get_ref(1)?.as_blob_or_null()?.map(|b| probe.hamming(b)).unwrap_or(u32::MAX);
            if let Some(b) = r.get_ref(2)?.as_blob_or_null()? {
                d = d.min(probe.hamming(b));
            }
            near.push((d, r.get(0)?));
        }
        if near.len() <= min_rows {
            return Ok(None);
        }
        near.sort_unstable();
        near.truncate(depth.max(n));
        let rids = serde_json::Value::from(near.iter().map(|(_, rid)| *rid).collect::<Vec<_>>()).to_string();
        let mut st = c.prepare_cached("SELECT m.id, m.embedding, m.embedding_alt FROM mh_memory m WHERE m.rid IN (SELECT value FROM json_each(?1))")?;
        let mut rows = st.query([rids])?;
        Ok(Some(scan(&mut rows, probe, true, n)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn match_query_is_safe_and_scoped() {
        assert_eq!(match_query("sabc0", "What's my dog's name? (it's & | !)").as_deref(), Some("stok:\"sabc0\" AND content:(\"dog\" OR \"name\")"));
        assert_eq!(match_query("sabc0", "!!!"), None);
        assert_eq!(match_query("sabc0", "the of and"), None);
        assert_eq!(match_query("sabc0", "NEAR(\"x\" OR *)").as_deref(), Some("stok:\"sabc0\" AND content:(\"near\")"));
    }
}
