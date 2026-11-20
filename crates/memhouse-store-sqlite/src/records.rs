// SPDX-License-Identifier: Apache-2.0
//! Writing and removing records inside a transaction the caller commits: one path for
//! `insert`, `import_records` and `apply_intake`, and one cascade for every kind of deletion.

use crate::util::*;
use crate::vector::{to_bits, to_half};
use crate::SqliteStore;
use chrono::{DateTime, SubsecRound, Utc};
use memhouse_core::format::RecordLine;
use memhouse_core::types::*;
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// A record and its vectors: one path for `insert` and `import_records`.
pub(crate) struct WriteRow<'a> {
    pub r: &'a RecordLine,
    pub embedding: Option<&'a [f32]>,
    pub alt: Option<&'a [f32]>,
}

// One argument per hashed field, in hash order; a struct would hide that order.
#[allow(clippy::too_many_arguments)]
pub(crate) fn audit_hash(prev: &str, at: &DateTime<Utc>, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<&str>, detail: &str) -> String {
    let mut h = Sha256::new();
    for part in [prev, &at.to_rfc3339_opts(chrono::SecondsFormat::Micros, true), actor, action, tenant, subject.unwrap_or(""), memory_id.unwrap_or(""), detail] {
        h.update(part.as_bytes());
        h.update([0x1f]);
    }
    hex::encode(h.finalize())
}

/// One audit event, chained to the last (the caller's transaction holds the write lock, so no
/// other event can take the same predecessor).
pub(crate) fn audit_in(c: &Connection, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<Uuid>, detail: &serde_json::Value) -> anyhow::Result<()> {
    let detail = detail.to_string();
    let at = Utc::now().trunc_subsecs(6);
    let memory_id = memory_id.map(|u| u.to_string());
    let prev: String = first(c, "SELECT hash FROM mh_audit ORDER BY id DESC LIMIT 1", [], |r| Ok(r.get(0)?))?.unwrap_or_else(|| "genesis".into());
    let hash = audit_hash(&prev, &at, actor, action, tenant, subject, memory_id.as_deref(), &detail);
    exec(
        c,
        "INSERT INTO mh_audit (at, actor, action, tenant, subject, memory_id, detail, prev_hash, hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![us(at), actor, action, tenant, subject, memory_id, detail, prev, hash],
    )?;
    Ok(())
}

/// The record lines of new memories (the shape `write_rows` takes).
pub(crate) fn lines_of(records: &[NewMemory]) -> Vec<RecordLine> {
    records
        .iter()
        .map(|n| {
            let m = &n.memory;
            RecordLine {
                id: m.id,
                tenant: m.tenant.clone(),
                subject: m.subject.clone(),
                kind: m.kind,
                status: m.status,
                content: m.content.clone(),
                content_hash: n.content_hash.clone(),
                session_id: m.session_id.clone(),
                turn_ref: m.turn_ref.clone(),
                occurred_at: m.occurred_at,
                valid_from: m.valid_from,
                valid_to: m.valid_to,
                expires_at: m.expires_at,
                supersedes: m.supersedes,
                superseded_by: None,
                labels: m.labels.clone(),
                tags: m.tags.clone(),
                scope: m.scope.clone(),
                source: m.source.clone(),
                confidence: m.confidence,
                provenance: m.provenance.clone(),
                language: m.language.clone(),
                alt_hash: n.alt.as_ref().map(|(h, _)| h.clone()),
                structured: n.structured.clone(),
                code_refs: n.code_refs.clone(),
                metadata: m.metadata.clone(),
                created_at: m.created_at,
                updated_at: m.created_at,
            }
        })
        .collect()
}

pub(crate) fn write_rows_of<'a>(lines: &'a [RecordLine], records: &'a [NewMemory]) -> Vec<WriteRow<'a>> {
    lines.iter().zip(records).map(|(r, n)| WriteRow { r, embedding: n.embedding.as_deref(), alt: n.alt.as_ref().map(|(_, v)| v.as_slice()) }).collect()
}

/// The ids in one of the metadata lists a deletion follows (`source_ids`, `promoted_from`).
fn listed(metadata: &serde_json::Value, key: &str) -> Vec<String> {
    metadata.get(key).and_then(|v| v.as_array()).into_iter().flatten().filter_map(|v| v.as_str().map(String::from)).collect()
}

/// Index the sources a record's metadata names (see `mh_source_ref`).
pub(crate) fn index_sources(c: &Connection, tenant: &str, id: &str, metadata: &serde_json::Value) -> anyhow::Result<()> {
    for (key, via) in [("source_ids", "source"), ("promoted_from", "promoted")] {
        for source in listed(metadata, key) {
            exec(c, "INSERT OR IGNORE INTO mh_source_ref (memory_id, tenant, source_id, via) VALUES (?1, ?2, ?3, ?4)", params![id, tenant, source, via])?;
        }
    }
    Ok(())
}

/// Remove enrichment jobs and, with `purge`, the cached extraction of each.
pub(crate) fn drop_jobs(c: &Connection, jobs: &[(i64, Option<String>)], purge: bool) -> anyhow::Result<()> {
    for (id, cache_key) in jobs {
        exec(c, "DELETE FROM mh_enrich_job WHERE id = ?1", [id])?;
        if let Some(key) = cache_key.as_ref().filter(|_| purge) {
            exec(c, "DELETE FROM mh_llm_cache WHERE key = ?1", [key])?;
        }
    }
    Ok(())
}

impl SqliteStore {
    /// Insert records with every column; `skip_existing` ignores ids already present. Returns
    /// the ids inserted.
    pub(crate) fn write_rows(&self, c: &Connection, rows: &[WriteRow<'_>], skip_existing: bool) -> anyhow::Result<Vec<Uuid>> {
        let ident = self.ident();
        let sql = format!(
            "INSERT INTO mh_memory (id, tenant, subject, stok, kind, status, content, content_hash, embedding, embedding_alt, embedding_bits, embedding_alt_bits, \
             alt_hash, embedder, embedder_config, session_id, turn_ref, occurred_at, valid_from, valid_to, expires_at, supersedes, superseded_by, labels, tags, \
             scope_org, scope_team, scope_agent, scope_user, scope_session, source, confidence, prov_agent, prov_user, policy_version, request_key, extractor, \
             extractor_config, metadata, created_at, updated_at, language) VALUES ({}){}",
            (1..=42).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", "),
            if skip_existing { " ON CONFLICT (id) DO NOTHING" } else { "" }
        );
        let mut inserted = vec![];
        for w in rows {
            let r = w.r;
            // The vector column of Postgres has one size; here the store checks it.
            if let Some(dim) = ident.as_ref().map(|i| i.dim) {
                for v in [w.embedding, w.alt].into_iter().flatten() {
                    anyhow::ensure!(v.len() == dim, "expected {dim} dimensions, not {}", v.len());
                }
            }
            let has_vec = w.embedding.is_some();
            let id = r.id.to_string();
            let n = exec(
                c,
                &sql,
                params![
                    id,
                    r.tenant,
                    r.subject,
                    crate::subject_token(&r.tenant, &r.subject),
                    r.kind.as_str(),
                    r.status.as_str(),
                    r.content,
                    r.content_hash,
                    w.embedding.map(to_half),
                    w.alt.map(to_half),
                    w.embedding.map(to_bits),
                    w.alt.map(to_bits),
                    w.alt.and(r.alt_hash.clone()),
                    ident.as_ref().filter(|_| has_vec).map(|i| i.embedder.clone()),
                    ident.as_ref().filter(|_| has_vec).map(|i| i.config.clone()),
                    r.session_id,
                    r.turn_ref,
                    r.occurred_at.map(us),
                    us(r.valid_from),
                    r.valid_to.map(us),
                    r.expires_at.map(us),
                    r.supersedes.map(|u| u.to_string()),
                    r.superseded_by.map(|u| u.to_string()),
                    json(&r.labels)?,
                    json(&r.tags)?,
                    r.scope.org,
                    r.scope.team,
                    r.scope.agent,
                    r.scope.user,
                    r.scope.session,
                    r.source,
                    r.confidence as f64,
                    r.provenance.agent,
                    r.provenance.user,
                    r.provenance.policy_version,
                    r.provenance.request_key,
                    r.provenance.extractor,
                    r.provenance.extractor_config,
                    r.metadata.to_string(),
                    us(r.created_at),
                    us(r.updated_at),
                    r.language
                ],
            )
            .map_err(|e| self.explain(c, e))?;
            if n == 0 {
                continue;
            }
            if let Some(st) = &r.structured {
                exec(
                    c,
                    "INSERT INTO mh_structured (memory_id, tenant, subject, record_type, attrs) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![id, r.tenant, r.subject, st.record_type, st.attrs.to_string()],
                )?;
            }
            for code in &r.code_refs {
                exec(
                    c,
                    "INSERT INTO mh_code_ref (memory_id, tenant, subject, path, blob_hash) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![id, r.tenant, r.subject, code.path, code.blob_hash],
                )?;
            }
            index_sources(c, &r.tenant, &id, &r.metadata)?;
            inserted.push(r.id);
        }
        Ok(inserted)
    }

    /// Drop the cached vectors of these contents and second-vector keys, under every model
    /// (every representation goes, TR-WF-01).
    pub(crate) fn purge_vectors<'a>(&self, c: &Connection, contents: impl IntoIterator<Item = &'a str>, alt_hashes: impl IntoIterator<Item = &'a str>) -> anyhow::Result<()> {
        for hash in contents.into_iter().map(|t| self.cache_hash(t)).chain(alt_hashes.into_iter().map(String::from)) {
            exec(c, "DELETE FROM mh_embed_cache WHERE hash = ?1", [hash])?;
        }
        Ok(())
    }

    /// Delete the records that name any of `sources` in their metadata, with their cached
    /// vectors: derived facts (`source_ids`) when `facts`, and promotions (`promoted_from`)
    /// when `promotions`. Returns the ids deleted.
    pub(crate) fn delete_dependents(&self, c: &Connection, tenant: &str, sources: &[Uuid], facts: bool, promotions: bool) -> anyhow::Result<Vec<Uuid>> {
        let found = rows(
            c,
            "SELECT DISTINCT m.id, m.content FROM mh_source_ref r JOIN mh_memory m ON m.id = r.memory_id \
             WHERE r.tenant = ?1 AND m.tenant = ?1 AND r.source_id IN (SELECT value FROM json_each(?2)) \
               AND ((?3 AND r.via = 'source') OR (?4 AND r.via = 'promoted'))",
            params![tenant, ids_json(sources), facts, promotions],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )?;
        let mut ids = Vec::with_capacity(found.len());
        for (id, content) in &found {
            exec(c, "DELETE FROM mh_memory WHERE tenant = ?1 AND id = ?2", [tenant, id.as_str()])?;
            self.purge_vectors(c, [content.as_str()], [])?;
            ids.push(uuid_of(id)?);
        }
        Ok(ids)
    }

    /// Erase a subject (see `Store::delete_subject`), inside the caller's transaction.
    pub(crate) fn delete_subject_in(&self, c: &Connection, tenant: &str, subject: &str, actor: &str, purge_cache: bool) -> anyhow::Result<u64> {
        // Queued writes first: nothing lands after an erasure.
        exec(c, "DELETE FROM mh_intake WHERE tenant = ?1 AND subject = ?2", [tenant, subject])?;
        if purge_cache {
            let held = rows(c, "SELECT content, alt_hash FROM mh_memory WHERE tenant = ?1 AND subject = ?2", [tenant, subject], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
            })?;
            self.purge_vectors(c, held.iter().map(|(t, _)| t.as_str()), held.iter().filter_map(|(_, h)| h.as_deref()))?;
        }
        let n = exec(c, "DELETE FROM mh_memory WHERE tenant = ?1 AND subject = ?2", [tenant, subject])?;
        // Links held by the subject and links to it from others, and remembered responses.
        exec(c, "DELETE FROM mh_link WHERE tenant = ?1 AND (subject = ?2 OR linked_subject = ?2)", [tenant, subject])?;
        exec(c, "DELETE FROM mh_request_key WHERE tenant = ?1 AND subject = ?2", [tenant, subject])?;
        exec(c, "DELETE FROM mh_recall WHERE tenant = ?1 AND subject = ?2", [tenant, subject])?;
        let jobs = rows(c, "SELECT id, cache_key FROM mh_enrich_job WHERE tenant = ?1 AND subject = ?2", [tenant, subject], |r| Ok((r.get(0)?, r.get(1)?)))?;
        drop_jobs(c, &jobs, purge_cache)?;
        exec(
            c,
            "INSERT INTO mh_deletion_ledger (at, tenant, subject, scope, actor) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![now(), tenant, subject, if purge_cache { "subject" } else { "subject-reset" }, actor],
        )?;
        Ok(n)
    }
}
