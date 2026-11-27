// SPDX-License-Identifier: Apache-2.0
//! Git-aware staleness (TPL-04, TR-TPL-02). A memory about code names the files it is about,
//! each with the content hash the file had (`CodeRef`). When a file is seen with other content,
//! deleted, or renamed with other content, the reference is marked stale and the memory is left
//! out of default recall until it is revalidated or revised.
//!
//! The rules are here, in one pure function ([`plan`]), so that every store applies the same
//! ones: a store loads the references at the paths an observation names, asks for the plan and
//! writes it in one transaction.

use crate::access::Decision;
use crate::engine::{Engine, RecallContext};
use crate::error;
use crate::metrics;
use crate::types::*;
use chrono::{DateTime, SubsecRound, Utc};
use sha2::Digest;
use std::collections::{BTreeMap, HashMap, HashSet};
use uuid::Uuid;

/// The most code references one memory may carry.
pub const MAX_CODE_REFS: usize = 200;

/// One stored reference: the memory it belongs to and the reference as stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefRow {
    pub id: Uuid,
    pub code: CodeRef,
}

/// What a store writes for one reference: the row at (`id`, `path`) becomes `now`, or is
/// removed when `now` is `None` (a rename onto a path the memory already references).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefUpdate {
    pub id: Uuid,
    /// The path the row is stored under before the update.
    pub path: String,
    pub now: Option<CodeRef>,
    /// What the update means for the reference; `None` when only the hash last seen changed
    /// on a reference that was stale already, or when the row is removed.
    pub change: Option<RefChange>,
}

/// The paths whose references an observation needs: each file's path and, for a rename, the
/// path it had before.
pub fn paths_of(files: &[FileState]) -> Vec<String> {
    let mut out: Vec<String> = files.iter().flat_map(|f| std::iter::once(f.path.clone()).chain(f.renamed_from.clone())).collect();
    out.sort();
    out.dedup();
    out
}

/// Apply file states, in order, to the references stored at their paths (`rows` holds every
/// reference at a path of [`paths_of`], of the records the observation applies to).
///
/// - A file seen with a hash other than the stored one: the reference is stale from `at` (or
///   from when it first became stale), and remembers the hash seen.
/// - A file seen with the stored hash: the reference is not stale.
/// - A deleted file: the reference is stale, with no hash seen.
/// - A renamed file: references to the old path move to the new one, then the new path is
///   judged by its hash like any other. A memory that already references the new path keeps
///   that reference, and the one to the old path is dropped.
pub fn plan(rows: &[RefRow], files: &[FileState], at: DateTime<Utc>) -> Vec<RefUpdate> {
    // Each stored reference as it is now, or `None` once it was dropped.
    let mut now: Vec<Option<CodeRef>> = rows.iter().map(|r| Some(r.code.clone())).collect();
    for f in files {
        if let Some(from) = &f.renamed_from {
            for i in 0..rows.len() {
                if now[i].as_ref().is_none_or(|c| c.path != *from) {
                    continue;
                }
                let taken = (0..rows.len()).any(|j| j != i && rows[j].id == rows[i].id && now[j].as_ref().is_some_and(|c| c.path == f.path));
                if taken {
                    now[i] = None;
                } else if let Some(c) = now[i].as_mut() {
                    c.path = f.path.clone();
                }
            }
        }
        for c in now.iter_mut().flatten().filter(|c| c.path == f.path) {
            match (&f.blob_hash, f.deleted) {
                (_, true) => {
                    c.stale_since.get_or_insert(at);
                    c.seen_hash = None;
                }
                (Some(h), false) if *h == c.blob_hash => {
                    c.stale_since = None;
                    c.seen_hash = None;
                }
                (Some(h), false) => {
                    c.stale_since.get_or_insert(at);
                    c.seen_hash = Some(h.clone());
                }
                // Not a valid state (`FileState::validate`): nothing is known about the file.
                (None, false) => {}
            }
        }
    }
    rows.iter()
        .zip(now)
        .filter(|(r, n)| n.as_ref() != Some(&r.code))
        .map(|(r, n)| {
            let change = n.as_ref().and_then(|c| {
                let (was, is) = (r.code.stale_since.is_some(), c.stale_since.is_some());
                let moved = c.path != r.code.path;
                (moved || was != is).then(|| RefChange {
                    id: r.id,
                    path: c.path.clone(),
                    moved_from: moved.then(|| r.code.path.clone()),
                    flagged: !was && is,
                    cleared: was && !is,
                    // The store fills both in: they depend on the memory's other references.
                    stale: is,
                    was_stale: was,
                })
            });
            RefUpdate { id: r.id, path: r.code.path.clone(), now: n, change }
        })
        .collect()
}

/// What a revalidation writes (see `Store::code_refs_revalidate`): with `given`, each named
/// reference takes the given hash; without, every stale reference takes the hash its file was
/// last seen with (one to a deleted file has none and stays stale). Returns the references
/// that change, as they are afterwards.
pub fn revalidated(stored: &[CodeRef], given: Option<&[CodeRef]>) -> anyhow::Result<Vec<CodeRef>> {
    match given {
        Some(given) => given
            .iter()
            .map(|g| {
                anyhow::ensure!(
                    !g.blob_hash.trim().is_empty() && g.blob_hash.len() <= 128,
                    crate::error::invalid(format!("code reference {:?}: blob_hash is 1 to 128 characters", g.path))
                );
                anyhow::ensure!(
                    stored.iter().any(|s| s.path == g.path),
                    crate::error::invalid(format!("the memory has no code reference to {:?}: expected one of its own paths (revise it to change them)", g.path))
                );
                Ok(g.as_written())
            })
            .collect(),
        None => Ok(stored.iter().filter(|s| s.stale_since.is_some()).filter_map(|s| s.seen_hash.as_ref().map(|h| CodeRef::new(s.path.clone(), h.clone()))).collect()),
    }
}

/// The hash algorithm of a git repository's objects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ObjectFormat {
    #[default]
    Sha1,
    Sha256,
}

/// The git blob hash of a file's content (what `git hash-object` prints): the hash of
/// `blob <length>\0` followed by the bytes. Computed here, so no git binary is needed.
pub fn git_blob_hash(content: &[u8], format: ObjectFormat) -> String {
    let header = format!("blob {}\0", content.len());
    match format {
        ObjectFormat::Sha1 => {
            let mut h = sha1::Sha1::new();
            h.update(header.as_bytes());
            h.update(content);
            hex::encode(h.finalize())
        }
        ObjectFormat::Sha256 => {
            let mut h = sha2::Sha256::new();
            h.update(header.as_bytes());
            h.update(content);
            hex::encode(h.finalize())
        }
    }
}

/// A repository path in the form references are stored in: `/` separators, no leading `./`,
/// no `.` or empty segments. `None` for a path that leaves the repository (`..`) or is empty.
pub fn normalize_path(path: &str) -> Option<String> {
    let unified = path.replace('\\', "/");
    let mut out: Vec<&str> = vec![];
    for seg in unified.split('/') {
        match seg {
            "" | "." => {}
            ".." => return None,
            s => out.push(s),
        }
    }
    (!out.is_empty()).then(|| out.join("/"))
}

/// The code references of a write, in the form they are stored in: each path normalized
/// ([`normalize_path`]) and named once, each with a hash, and without staleness marks, which
/// are the server's to set.
pub fn written_refs(refs: &[CodeRef]) -> anyhow::Result<Vec<CodeRef>> {
    if refs.len() > MAX_CODE_REFS {
        return Err(error::invalid(format!("a memory carries at most {MAX_CODE_REFS} code references; the limit is {MAX_CODE_REFS}")));
    }
    let mut seen = HashSet::new();
    refs.iter()
        .map(|r| {
            let path = normalize_path(&r.path)
                .filter(|p| p.len() <= MAX_PATH_LEN)
                .ok_or_else(|| error::invalid(format!("code reference {:?}: expected a path inside the repository, of at most {MAX_PATH_LEN} characters", r.path)))?;
            if r.blob_hash.trim().is_empty() || r.blob_hash.len() > 128 {
                return Err(error::invalid(format!("code reference {path:?}: blob_hash is required, 1 to 128 characters")));
            }
            if !seen.insert(path.clone()) {
                return Err(error::invalid(format!("code reference {path:?}: expected each path once")));
            }
            Ok(CodeRef::new(path, r.blob_hash.trim()))
        })
        .collect()
}

/// File states as a request may give them: valid, with normalized paths, at most `MAX_FILES`.
pub fn observed_files(files: &[FileState]) -> anyhow::Result<Vec<FileState>> {
    if files.is_empty() || files.len() > MAX_FILES {
        return Err(error::invalid(format!("files is required: 1 to {MAX_FILES} files; the limit is {MAX_FILES}")));
    }
    let outside = |p: &str| error::invalid(format!("file {p:?}: expected a path inside the repository"));
    files
        .iter()
        .map(|f| {
            f.validate()?;
            Ok(FileState {
                path: normalize_path(&f.path).ok_or_else(|| outside(&f.path))?,
                blob_hash: f.blob_hash.as_ref().map(|h| h.trim().to_string()),
                deleted: f.deleted,
                renamed_from: f.renamed_from.as_ref().map(|p| normalize_path(p).ok_or_else(|| outside(p))).transpose()?,
            })
        })
        .collect()
}

/// A file-touched answer as text for an agent's context (the MCP tool and the harness hooks
/// print it): the linked memories, then those to check against the file first.
pub fn touched_text(subject: &str, files: &[String], r: &FileTouchedResult) -> String {
    let line = |m: &Memory| format!("- [{}] ({}, {}) {}", m.id, m.kind, m.created_at.format("%Y-%m-%d"), m.content.replace('\n', " "));
    let about = if files.len() == 1 { files[0].clone() } else { format!("{} files", files.len()) };
    let mut out: Vec<String> = vec![];
    if !r.memories.is_empty() {
        out.push(format!("Memories about {about} ({subject}):"));
        out.extend(r.memories.iter().map(|l| line(&l.memory)));
    }
    if !r.related.is_empty() {
        out.push("Procedures that match the task:".into());
        out.extend(r.related.iter().map(line));
    }
    if !r.needs_revalidation.is_empty() {
        out.push(format!(
            "Written about an earlier version of {about}: check each against the file as it is now, then revalidate it if it still holds, or revise or forget it. Until then it is left out of recall."
        ));
        for l in &r.needs_revalidation {
            let stale: Vec<&str> = l.code_refs.iter().filter(|c| c.stale_since.is_some()).map(|c| c.path.as_str()).collect();
            out.push(format!("{} (changed: {})", line(&l.memory), if stale.is_empty() { about.clone() } else { stale.join(", ") }));
        }
    }
    out.join("\n")
}

/// Exactly what a recall would let a reader see at `now`: committed, valid, unexpired, and
/// inside the reader's tenant, labels, kinds and scope. Staleness is the one filter left open.
pub(crate) fn recallable_now(m: &Memory, reader: &Decision, now: DateTime<Utc>) -> bool {
    m.status == MemoryStatus::Committed && reader.visible(m) && m.valid_from <= now && m.valid_to.is_none_or(|t| t > now) && m.expires_at.is_none_or(|t| t > now)
}

fn unranked(memory: Memory) -> Hit {
    Hit { memory, score: 0.0, keyword_rank: None, vector_rank: None, similarity: None, rerank_score: None, exact: false, working: false, embedding: None, features: None }
}

impl Engine {
    /// Record what files of a repository were seen as (TPL-04): references whose stored hash
    /// differs become stale, those seen with their stored content again stop being stale, and
    /// a rename moves them. Every memory whose state changed gets an audit event
    /// (`memory.stale`, `memory.fresh`, `memory.code_moved`) with `why` in its detail. Returns
    /// every change, whoever may read the memory: callers filter what they show.
    pub async fn files_observed(&self, tenant: &str, subject: &str, files: &[FileState], actor: &str, why: serde_json::Value) -> anyhow::Result<Vec<RefChange>> {
        let files = observed_files(files)?;
        // The precision every store keeps, so the same observation reads the same in each.
        let at = Utc::now().trunc_subsecs(6);
        // One event per memory and kind of change, written by the store in the transaction of
        // the changes themselves.
        let events = |changes: &[RefChange]| -> Vec<crate::intake::AuditEntry> {
            let mut by_memory: BTreeMap<Uuid, Vec<&RefChange>> = BTreeMap::new();
            for c in changes {
                by_memory.entry(c.id).or_default().push(c);
            }
            let mut out = vec![];
            for (id, of) in &by_memory {
                let paths = |pick: &dyn Fn(&RefChange) -> bool| -> Vec<serde_json::Value> {
                    of.iter().filter(|c| pick(c)).map(|c| serde_json::json!({ "path": c.path, "moved_from": c.moved_from })).collect()
                };
                let stale = of.iter().any(|c| c.stale);
                for (action, picked) in [
                    ("memory.stale", paths(&|c| c.flagged)),
                    ("memory.fresh", paths(&|c| c.cleared)),
                    ("memory.code_moved", paths(&|c| c.moved_from.is_some() && !c.flagged && !c.cleared)),
                ] {
                    if !picked.is_empty() {
                        out.push(crate::intake::AuditEntry {
                            actor: actor.to_string(),
                            action: action.into(),
                            subject: Some(subject.to_string()),
                            memory_id: Some(*id),
                            detail: serde_json::json!({ "files": picked, "stale": stale, "why": why }),
                        });
                    }
                }
            }
            out
        };
        let changes = self.store.code_refs_observe(tenant, subject, &files, at, &events).await?;
        for (label, n) in [
            ("flagged", changes.iter().filter(|c| c.flagged).count()),
            ("cleared", changes.iter().filter(|c| c.cleared).count()),
            ("moved", changes.iter().filter(|c| c.moved_from.is_some() && !c.flagged && !c.cleared).count()),
        ] {
            if n > 0 {
                metrics::inc("memhouse_code_refs_total", &[("change", label)], n as f64);
            }
        }
        // The session cache holds copies of working memory: drop the changed ones, so the next
        // recall reads their state from the store.
        for id in changes.iter().map(|c| c.id).collect::<HashSet<_>>() {
            self.working.drop_record(id);
        }
        Ok(changes)
    }

    /// File-touched recall (TPL-05) for a reader whose read constraints are `reader`: with
    /// `mark`, the files' states are recorded first; then every memory linked to the files
    /// that the reader may recall is returned, split by staleness.
    pub(crate) async fn file_touched_with(&self, req: FileTouchedRequest, reader: &Decision, ctx: RecallContext, mark: bool) -> anyhow::Result<FileTouchedResult> {
        let start = std::time::Instant::now();
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let actor = req.actor.clone().unwrap_or_else(|| ctx.principal.clone());
        let files = observed_files(&req.files)?;
        let all_changes =
            if mark { self.files_observed(&tenant, &subject, &files, &actor, serde_json::json!({ "event": format!("file.{}", req.event.as_str()) })).await? } else { vec![] };
        let paths: Vec<String> = files.iter().map(|f| f.path.clone()).collect();
        // A reader whose observation is not recorded moved nothing: the references to a
        // renamed file are still at the path it had before.
        let lookup: Vec<String> = if mark { paths.clone() } else { paths_of(&files) };
        let refs = self.store.code_refs_at(&tenant, &subject, &lookup).await?;
        let mut ids: Vec<Uuid> = refs.iter().map(|(id, _)| *id).chain(all_changes.iter().map(|c| c.id)).collect();
        ids.sort();
        ids.dedup();
        let now = Utc::now();
        let recallable = |m: &Memory| m.subject == subject && recallable_now(m, reader, now);
        let seen: HashMap<Uuid, Memory> = self.store.get_many(&tenant, &ids).await?.into_iter().filter(recallable).map(|m| (m.id, m)).collect();
        let mut linked: BTreeMap<Uuid, Vec<CodeRef>> = BTreeMap::new();
        for (id, code) in refs {
            if seen.contains_key(&id) {
                linked.entry(id).or_default().push(code);
            }
        }
        let mut result = FileTouchedResult { changes: all_changes.into_iter().filter(|c| seen.contains_key(&c.id)).collect(), ..Default::default() };
        // For a reader whose observation is not recorded: the same comparison, for this answer.
        let differs = |code: &CodeRef| {
            files.iter().any(|f| {
                (f.path == code.path || f.renamed_from.as_deref() == Some(code.path.as_str())) && (f.deleted || f.blob_hash.as_deref().is_some_and(|h| h != code.blob_hash))
            })
        };
        for (id, at_paths) in linked {
            let memory = seen[&id].clone();
            if memory.stale_since.is_some() || (!mark && at_paths.iter().any(differs)) {
                // All of its references: the stale one may be to a file this request did not name.
                let code_refs = self.store.representations(&tenant, id).await?.1;
                result.needs_revalidation.push(LinkedMemory { memory, code_refs });
            } else {
                result.memories.push(LinkedMemory { memory, code_refs: at_paths });
            }
        }
        // Newest first, like a list.
        for list in [&mut result.memories, &mut result.needs_revalidation] {
            list.sort_by_key(|l| std::cmp::Reverse((l.memory.created_at, l.memory.id)));
        }
        // With a task, procedures that match it and are not linked to the files (MEM-02).
        let wants_procedures = reader.kinds.is_empty() || reader.kinds.contains(&MemoryKind::Procedural);
        if let Some(query) = req.query.as_ref().filter(|q| !q.trim().is_empty() && wants_procedures) {
            let ask = RecallRequest {
                tenant: Some(tenant.clone()),
                subject: Some(subject.clone()),
                query: query.clone(),
                kinds: Some(vec![MemoryKind::Procedural]),
                scope: Some(reader.scope.clone()).filter(|s| !s.is_empty()),
                paths: paths.clone(),
                actor: Some(actor.clone()),
                ..Default::default()
            };
            let ctx = RecallContext {
                principal: ctx.principal.clone(),
                user: ctx.user.clone(),
                denied_labels: ctx.denied_labels.clone(),
                authorizer: ctx.authorizer.clone(),
                shared_agents: ctx.shared_agents.clone(),
            };
            let linked_ids: HashSet<Uuid> = result.memories.iter().chain(&result.needs_revalidation).map(|l| l.memory.id).collect();
            result.related = self.recall_with(ask, ctx).await?.hits.into_iter().map(|h| h.memory).filter(|m| !linked_ids.contains(&m.id)).collect();
        }
        if req.render {
            let hits: Vec<Hit> = result.memories.iter().map(|l| l.memory.clone()).chain(result.related.iter().cloned()).map(unranked).collect();
            result.rendered = (!hits.is_empty()).then(|| crate::pack::render(&subject, &hits, RenderFormat::Plain));
        }
        if self.policy_for(&tenant).await?.policy.recall.audit_reads {
            let returned: Vec<Uuid> = result.memories.iter().chain(&result.needs_revalidation).map(|l| l.memory.id).collect();
            self.store
                .audit(&actor, "memory.recall", &tenant, Some(&subject), None, serde_json::json!({ "returned": returned, "via": format!("file.{}", req.event.as_str()) }))
                .await?;
        }
        metrics::inc("memhouse_operations_total", &[("op", "file_touched"), ("outcome", "ok")], 1.0);
        metrics::observe("memhouse_operation_duration_seconds", &[("op", "file_touched")], start.elapsed().as_secs_f64());
        Ok(result)
    }

    /// File-touched recall as the operator (the benchmark and tests): every scope, the
    /// tenant's denied labels.
    pub async fn file_touched(&self, req: FileTouchedRequest) -> anyhow::Result<FileTouchedResult> {
        let tenant = self.tenant(&req.tenant);
        let policy = self.policy_for(&tenant).await?;
        let denied_labels = crate::engine::with_policy_labels(&self.cfg.governance.denied_labels, &policy);
        let reader = Decision {
            allowed: true,
            rule: "operator".into(),
            reasons: vec![],
            tenant,
            denied_labels: denied_labels.clone(),
            scope: Scope::default(),
            kinds: vec![],
            propose_only: false,
            shared_agents: vec![],
        };
        let ctx = RecallContext { principal: req.actor.clone().unwrap_or_else(|| "api".into()), user: None, denied_labels, authorizer: "operator".into(), shared_agents: vec![] };
        self.file_touched_with(req, &reader, ctx, true).await
    }

    /// Revalidate a memory (TPL-04): its references take the given hashes, or the hashes their
    /// files were last seen with, and the memory returns to default recall once none is stale.
    /// Audited as `memory.revalidate`.
    pub async fn revalidate(&self, tenant: &str, m: &Memory, refs: Option<&[CodeRef]>, actor: &str) -> anyhow::Result<RevalidateResult> {
        if m.status != MemoryStatus::Committed {
            return Err(error::conflict(format!("memory {} is {}; only a committed memory is revalidated", m.id, m.status.as_str())));
        }
        let given = refs.map(written_refs).transpose()?;
        let before = self.store.representations(tenant, m.id).await?.1;
        if before.is_empty() {
            return Err(error::invalid(format!("memory {} has no code references: expected a memory linked to files", m.id)));
        }
        // Refused before anything is written: a path that is no reference, an empty hash.
        revalidated(&before, given.as_deref())?;
        if given.is_none() {
            // Nothing was seen of a deleted file: there is no content to confirm the memory against.
            if let Some(gone) = before.iter().find(|r| r.stale_since.is_some() && r.seen_hash.is_none()) {
                return Err(error::invalid(format!(
                    "the file {:?} was deleted: expected code_refs with the hash of the file the memory is about now, or revise or forget the memory",
                    gone.path
                )));
            }
        }
        // The event is built from what the store's transaction read and wrote, not from the
        // read above: an observation may record another hash in between.
        let written = std::sync::atomic::AtomicUsize::new(0);
        let event = |was: &[CodeRef], wrote: &[CodeRef], now: &[CodeRef]| -> Vec<crate::intake::AuditEntry> {
            written.store(wrote.len(), std::sync::atomic::Ordering::Relaxed);
            let refs: Vec<serde_json::Value> = wrote
                .iter()
                .map(|r| {
                    let old = was.iter().find(|b| b.path == r.path);
                    serde_json::json!({ "path": r.path, "from": old.map(|b| b.blob_hash.clone()), "to": r.blob_hash, "was_stale": old.is_some_and(|b| b.stale_since.is_some()) })
                })
                .collect();
            vec![crate::intake::AuditEntry {
                actor: actor.to_string(),
                action: "memory.revalidate".into(),
                subject: Some(m.subject.clone()),
                memory_id: Some(m.id),
                detail: serde_json::json!({ "refs": refs, "stale": now.iter().any(|r| r.stale_since.is_some()) }),
            }]
        };
        let after = self.store.code_refs_revalidate(tenant, m.id, given.as_deref(), &event).await?.ok_or_else(|| error::not_found(format!("memory {} not found", m.id)))?;
        self.working.drop_record(m.id);
        let stale = after.iter().any(|r| r.stale_since.is_some());
        metrics::inc("memhouse_code_refs_total", &[("change", "revalidated")], written.load(std::sync::atomic::Ordering::Relaxed) as f64);
        Ok(RevalidateResult { id: m.id, code_refs: after, stale })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: u128, path: &str, hash: &str) -> RefRow {
        RefRow { id: Uuid::from_u128(id), code: CodeRef::new(path, hash) }
    }

    fn at() -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000, 0).unwrap()
    }

    #[test]
    fn a_changed_hash_flags_and_the_stored_hash_clears() {
        let rows = vec![row(1, "src/a.rs", "h1"), row(2, "src/a.rs", "h2"), row(3, "src/b.rs", "h1")];
        let ups = plan(&rows, &[FileState::present("src/a.rs", "h2")], at());
        // Only the reference whose stored hash differs changes; another path is not touched.
        assert_eq!(ups.len(), 1);
        let c = ups[0].change.clone().unwrap();
        assert!(c.flagged && !c.cleared && c.id == Uuid::from_u128(1) && c.moved_from.is_none());
        let stale = ups[0].now.clone().unwrap();
        assert_eq!((stale.stale_since, stale.seen_hash.as_deref()), (Some(at()), Some("h2")));
        // Seen again with another hash: still stale since the first time, the hash updated, no change reported.
        let rows2 = vec![RefRow { id: rows[0].id, code: stale.clone() }];
        let later = at() + chrono::Duration::hours(1);
        let ups2 = plan(&rows2, &[FileState::present("src/a.rs", "h3")], later);
        assert_eq!((ups2[0].now.as_ref().unwrap().stale_since, ups2[0].now.as_ref().unwrap().seen_hash.as_deref(), ups2[0].change.is_none()), (Some(at()), Some("h3"), true));
        // Seen with the stored hash again: cleared.
        let ups3 = plan(&rows2, &[FileState::present("src/a.rs", "h1")], later);
        assert!(ups3[0].change.as_ref().unwrap().cleared && ups3[0].now.as_ref().unwrap().stale_since.is_none());
        // The same hash on a reference that is not stale: nothing to write.
        assert!(plan(&rows, &[FileState::present("src/b.rs", "h1")], at()).is_empty());
    }

    #[test]
    fn deletions_and_renames() {
        let rows = vec![row(1, "old.rs", "h1"), row(2, "old.rs", "h9"), row(3, "new.rs", "h1"), row(3, "old.rs", "h1")];
        let gone = plan(&rows[..1], &[FileState::deleted("old.rs")], at());
        assert!(gone[0].change.as_ref().unwrap().flagged && gone[0].now.as_ref().unwrap().seen_hash.is_none());
        let ups = plan(&rows, &[FileState::renamed("old.rs", "new.rs", "h1")], at());
        let of = |id: u128, path: &str| ups.iter().find(|u| u.id == Uuid::from_u128(id) && u.path == path);
        // Same content under the new name: moved, not stale.
        let moved = of(1, "old.rs").unwrap();
        assert_eq!(moved.now.as_ref().unwrap().path, "new.rs");
        assert!(
            moved.now.as_ref().unwrap().stale_since.is_none() && moved.change.as_ref().unwrap().moved_from.as_deref() == Some("old.rs") && !moved.change.as_ref().unwrap().flagged
        );
        // Other content under the new name: moved and stale.
        assert!(of(2, "old.rs").unwrap().change.as_ref().unwrap().flagged);
        // A memory that already references the new path keeps that one; the old one is dropped.
        assert!(of(3, "old.rs").unwrap().now.is_none() && of(3, "new.rs").is_none());
        // A rename then an edit in one batch: judged by the last state.
        let both = plan(&rows[..1], &[FileState::renamed("old.rs", "new.rs", "h1"), FileState::present("new.rs", "h2")], at());
        assert!(both[0].change.as_ref().unwrap().flagged && both[0].now.as_ref().unwrap().path == "new.rs");
    }

    #[test]
    fn revalidation() {
        let mut stale = CodeRef::new("a.rs", "h1");
        (stale.stale_since, stale.seen_hash) = (Some(at()), Some("h2".into()));
        let mut gone = CodeRef::new("b.rs", "h1");
        gone.stale_since = Some(at());
        let stored = vec![stale, gone, CodeRef::new("c.rs", "h1")];
        assert_eq!(revalidated(&stored, None).unwrap(), vec![CodeRef::new("a.rs", "h2")]);
        assert_eq!(revalidated(&stored, Some(&[CodeRef::new("b.rs", "h5")])).unwrap(), vec![CodeRef::new("b.rs", "h5")]);
        assert!(revalidated(&stored, Some(&[CodeRef::new("zzz.rs", "h5")])).is_err());
    }

    #[test]
    fn blob_hashes_are_gits() {
        // `printf 'hello\n' | git hash-object --stdin`, and the empty blob.
        assert_eq!(git_blob_hash(b"hello\n", ObjectFormat::Sha1), "ce013625030ba8dba906f756967f9e9ca394464a");
        assert_eq!(git_blob_hash(b"", ObjectFormat::Sha1), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
        // The empty blob of a SHA-256 repository.
        assert_eq!(git_blob_hash(b"", ObjectFormat::Sha256), "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813");
    }

    #[test]
    fn paths() {
        assert_eq!(normalize_path("./src//a.rs").as_deref(), Some("src/a.rs"));
        assert_eq!(normalize_path("src\\win\\a.rs").as_deref(), Some("src/win/a.rs"));
        assert_eq!(normalize_path("../outside"), None);
        assert_eq!(normalize_path("./"), None);
    }
}
