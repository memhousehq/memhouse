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
    /// What the update means for the reference. Every update has one, so that every write
    /// is audited: a transition, a move, a reference merged into another by a rename, or
    /// only another hash seen on a reference that was stale already (`seen_only`).
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
    // For a dropped reference: the path of the reference that took its place.
    let mut merged: Vec<Option<String>> = vec![None; rows.len()];
    for f in files {
        if let Some(from) = &f.renamed_from {
            for i in 0..rows.len() {
                if now[i].as_ref().is_none_or(|c| c.path != *from) {
                    continue;
                }
                let taken = (0..rows.len()).any(|j| j != i && rows[j].id == rows[i].id && now[j].as_ref().is_some_and(|c| c.path == f.path));
                if taken {
                    now[i] = None;
                    merged[i] = Some(f.path.clone());
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
        .zip(merged)
        .filter(|((r, n), _)| n.as_ref() != Some(&r.code))
        .map(|((r, n), merged)| {
            let was = r.code.stale_since.is_some();
            let change = match &n {
                Some(c) => {
                    let is = c.stale_since.is_some();
                    let moved = c.path != r.code.path;
                    let seen_only = !moved && was == is;
                    RefChange {
                        id: r.id,
                        path: c.path.clone(),
                        moved_from: moved.then(|| r.code.path.clone()),
                        flagged: !was && is,
                        cleared: was && !is,
                        // The store fills both in: they depend on the memory's other references.
                        stale: is,
                        was_stale: was,
                        seen_only,
                        seen_hash: c.seen_hash.clone().filter(|_| seen_only),
                    }
                }
                // Merged into the reference the memory already has at the new path: reported
                // as a move there, and as cleared when the dropped reference was stale, so
                // that a memory this leaves fresh is audited and leaves the session cache.
                None => RefChange {
                    id: r.id,
                    path: merged.unwrap_or_else(|| r.code.path.clone()),
                    moved_from: Some(r.code.path.clone()),
                    flagged: false,
                    cleared: was,
                    stale: false,
                    was_stale: was,
                    seen_only: false,
                    seen_hash: None,
                },
            };
            RefUpdate { id: r.id, path: r.code.path.clone(), now: n, change: Some(change) }
        })
        .collect()
}

/// The references a revision takes from the version it replaces when it names none of its
/// own: each with the hash its file was last seen with, which is what the reviser had before
/// them; a reference to a deleted file is not carried over. This is what the reviser read;
/// what the revision is stored with is decided by [`successor_refs`].
pub fn inherited_refs(predecessor: &[CodeRef]) -> Vec<CodeRef> {
    predecessor
        .iter()
        .filter_map(|r| match (&r.stale_since, &r.seen_hash) {
            (None, _) => Some(r.as_written()),
            (Some(_), Some(h)) => Some(CodeRef::new(r.path.clone(), h.clone())),
            (Some(_), None) => None,
        })
        .collect()
}

/// The references a revision is stored with (TPL-04): `own` is what the reviser read or
/// named when the revision was made, `predecessor` the references of the version it replaces
/// as they are when the revision is stored. A store calls this in the transaction that inserts
/// the revision, so no observation of a file can fall between the judgement and the insert.
///
/// - `inherited` (the revision named none of its own; `own` is [`inherited_refs`] as read
///   then): one reference per reference the predecessor has now, at the path it has now, with
///   the hash the reviser read. Where the file is known with another content now (changed,
///   restored or deleted since the reviser read it), the reference starts stale: the revision
///   was written about content the file no longer has. A file renamed since, with the content
///   the reviser read, is followed. Where what the reviser read cannot be told (the path
///   changed and the content with it), the reference keeps the predecessor's hash and starts
///   stale. A file renamed and then deleted since is kept, stale. A reference to a file that
///   was already deleted when the reviser read is dropped.
/// - Otherwise the revision's own references. One whose file was seen, on the predecessor,
///   with another hash than the revision names (or deleted) starts stale. A hash the
///   predecessor never saw is the writer's statement and is taken as fresh.
pub fn successor_refs(own: &[CodeRef], inherited: bool, predecessor: &[CodeRef], at: DateTime<Utc>) -> Vec<CodeRef> {
    if !inherited {
        return own
            .iter()
            .map(|r| {
                let mut r = r.as_written();
                if let Some(was) = predecessor.iter().find(|o| o.path == r.path && o.stale_since.is_some() && o.seen_hash.as_deref() != Some(r.blob_hash.as_str())) {
                    (r.stale_since, r.seen_hash) = (was.stale_since, was.seen_hash.clone());
                }
                r
            })
            .collect();
    }
    // What is known of each file now: the hash last seen, or none for a deleted file.
    let known = |p: &CodeRef| if p.stale_since.is_some() { p.seen_hash.clone() } else { Some(p.blob_hash.clone()) };
    let stale = |path: &str, hash: &str, p: &CodeRef| {
        let mut r = CodeRef::new(path, hash);
        (r.stale_since, r.seen_hash) = (Some(p.stale_since.unwrap_or(at)), known(p));
        r
    };
    // References the reviser read whose path the predecessor no longer has: renamed since.
    let mut moved: Vec<&CodeRef> = own.iter().filter(|c| !predecessor.iter().any(|p| p.path == c.path)).collect();
    let mut out: Vec<Option<CodeRef>> = predecessor
        .iter()
        .map(|p| {
            let now = known(p);
            if let Some(read) = own.iter().find(|c| c.path == p.path) {
                return Some(if now.as_deref() == Some(read.blob_hash.as_str()) { read.as_written() } else { stale(&p.path, &read.blob_hash, p) });
            }
            // Not among what the reviser read; a deleted one is settled below.
            let now = now?;
            Some(match moved.iter().position(|c| c.blob_hash == now) {
                Some(i) => CodeRef::new(p.path.clone(), moved.remove(i).blob_hash.clone()),
                None => stale(&p.path, &p.blob_hash, p),
            })
        })
        .collect();
    // A deleted file at a path the reviser did not read. Deleted before the reviser read:
    // not carried over then, and dropped now. Renamed and then deleted since: the reviser
    // read it under its old path, which is then still unaccounted for, and the revision
    // keeps the reference, stale, so that it is not recalled as if nothing had happened.
    // Where both happened, the files deleted last are the ones the reviser still read.
    let mut gone: Vec<usize> = (0..predecessor.len()).filter(|i| out[*i].is_none() && !own.iter().any(|c| c.path == predecessor[*i].path)).collect();
    gone.sort_by_key(|i| std::cmp::Reverse(predecessor[*i].stale_since));
    for i in gone.into_iter().take(moved.len()) {
        out[i] = Some(stale(&predecessor[i].path, &moved.remove(0).blob_hash, &predecessor[i]));
    }
    out.into_iter().flatten().collect()
}

/// References as they are after file states are applied to them, in order, for an answer
/// that records nothing: the same rules as [`plan`], on a copy.
pub fn applied(id: Uuid, refs: &[CodeRef], files: &[FileState], at: DateTime<Utc>) -> Vec<CodeRef> {
    let rows: Vec<RefRow> = refs.iter().map(|c| RefRow { id, code: c.clone() }).collect();
    let updates = plan(&rows, files, at);
    refs.iter()
        .filter_map(|c| match updates.iter().find(|u| u.path == c.path) {
            Some(u) => u.now.clone(),
            None => Some(c.clone()),
        })
        .collect()
}

/// Stored paths that are not in the form references are matched in ([`normalize_path`]):
/// written before paths were normalized on write. For each such row of `rows` (memory, path),
/// the path it gets, or `None` when the memory already has a reference at that path (the row
/// is then removed: the one in canonical form is kept, else the first by path). A path that
/// cannot be normalized is left as it is.
pub fn canonical_paths(rows: &[(Uuid, String)]) -> Vec<(Uuid, String, Option<String>)> {
    let mut taken: HashSet<(Uuid, String)> = rows.iter().filter(|(_, p)| normalize_path(p).as_deref() == Some(p.as_str())).cloned().collect();
    let mut rest: Vec<&(Uuid, String)> = rows.iter().filter(|(id, p)| !taken.contains(&(*id, p.clone()))).collect();
    rest.sort();
    rest.into_iter()
        .filter_map(|(id, p)| {
            let to = normalize_path(p).filter(|n| n.len() <= MAX_PATH_LEN)?;
            Some((*id, p.clone(), taken.insert((*id, to.clone())).then_some(to)))
        })
        .collect()
}

/// How many stored paths have no canonical form ([`canonical_paths`] leaves them as they
/// are): one that leaves the repository (`..`), an empty one, or one that is too long. Such a
/// reference never matches a report of a file, so an upgrade says how many there are.
pub fn uncanonical_paths(rows: &[(Uuid, String)]) -> usize {
    rows.iter().filter(|(_, p)| normalize_path(p).is_none_or(|n| n.len() > MAX_PATH_LEN)).count()
}

/// What a revalidation writes (see `Store::code_refs_revalidate`): with `given`, each named
/// reference takes the given hash; without, every stale reference takes the hash its file was
/// last seen with (one to a deleted file has none and stays stale). Returns the references
/// that change, as they are afterwards.
///
/// A given hash confirms the memory against that content only. Where the file was since seen
/// with another one, or deleted (`stored` is read in the transaction that writes), the reference takes
/// the given hash and stays stale, with the hash seen: the confirmation must not hide a
/// change it did not look at. It stops being stale when the file is seen with the confirmed
/// content, or is confirmed against what was seen. For the same reason a given hash other
/// than the stored one is refused (a conflict) for a reference that is not stale.
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
                // A reference that is not stale was last known with its stored hash: written
                // with it, or seen with it since (a file changed and changed back). Another
                // hash is content MemHouse has not seen for it, so nothing tells a file that
                // was checked before it changed back from one that is like that now.
                anyhow::ensure!(
                    !stored.iter().any(|s| s.path == g.path && s.stale_since.is_none() && s.blob_hash != g.blob_hash),
                    crate::error::conflict(format!(
                        "the code reference to {:?} is not stale: its file was last known with the stored hash, not the one given. Report the file as it is now (file-touched recall, or files changed), then revalidate; or revise the memory to say what it is about",
                        g.path
                    ))
                );
                let mut now = g.as_written();
                // Also after a deletion (no hash seen): the last report says the file is gone,
                // and the confirmation may be of the file before that.
                if let Some(s) = stored.iter().find(|s| s.path == g.path && s.stale_since.is_some() && s.seen_hash.as_deref() != Some(g.blob_hash.as_str())) {
                    (now.stale_since, now.seen_hash) = (s.stale_since, s.seen_hash.clone());
                }
                Ok(now)
            })
            .collect(),
        None => Ok(stored.iter().filter(|s| s.stale_since.is_some()).filter_map(|s| s.seen_hash.as_ref().map(|h| CodeRef::new(s.path.clone(), h.clone()))).collect()),
    }
}

/// Only a committed record is revalidated. A store checks it again on the row it has locked:
/// the record may have been superseded since the caller read it.
pub fn revalidated_status(id: Uuid, status: &str) -> anyhow::Result<()> {
    anyhow::ensure!(status == MemoryStatus::Committed.as_str(), error::conflict(format!("memory {id} is {status}; only a committed memory is revalidated")));
    Ok(())
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
    /// (`memory.stale`, `memory.fresh`, `memory.code_moved`) with `why` in its detail; another
    /// hash seen on a reference that was stale already is audited as `memory.code_seen` and
    /// is no transition. Returns every transition and move, whoever may read the memory:
    /// callers filter what they show.
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
                    of.iter()
                        .filter(|c| pick(c))
                        .map(|c| {
                            if c.seen_only {
                                serde_json::json!({ "path": c.path, "seen_hash": c.seen_hash })
                            } else {
                                serde_json::json!({ "path": c.path, "moved_from": c.moved_from })
                            }
                        })
                        .collect()
                };
                let stale = of.iter().any(|c| c.stale);
                for (action, picked) in [
                    ("memory.stale", paths(&|c| c.flagged)),
                    ("memory.fresh", paths(&|c| c.cleared)),
                    ("memory.code_moved", paths(&|c| c.moved_from.is_some() && !c.flagged && !c.cleared)),
                    // The hash a later revalidation without `code_refs` would take.
                    ("memory.code_seen", paths(&|c| c.seen_only)),
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
        let mut changes = self.store.code_refs_observe(tenant, subject, &files, at, &events).await?;
        changes.retain(|c| !c.seen_only);
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
        for (id, at_paths) in linked {
            let memory = seen[&id].clone();
            if mark {
                if memory.stale_since.is_some() {
                    // All of its references: the stale one may be to a file this request did not name.
                    let code_refs = self.store.representations(&tenant, id).await?.1;
                    result.needs_revalidation.push(LinkedMemory { memory, code_refs });
                } else {
                    result.memories.push(LinkedMemory { memory, code_refs: at_paths });
                }
                continue;
            }
            // For a reader whose observation is not recorded: the same rules, applied in the
            // same order to a copy of the references, for this answer alone. A memory that is
            // stale may be so by a reference this request did not name: all of them count.
            let mut code_refs = applied(id, &at_paths, &files, now);
            if memory.stale_since.is_some() || code_refs.iter().any(|c| c.stale_since.is_some()) {
                code_refs = applied(id, &self.store.representations(&tenant, id).await?.1, &files, now);
            }
            if code_refs.iter().any(|c| c.stale_since.is_some()) {
                result.needs_revalidation.push(LinkedMemory { memory, code_refs });
            } else {
                let named: Vec<CodeRef> = code_refs.into_iter().filter(|c| paths.contains(&c.path)).collect();
                result.memories.push(LinkedMemory { memory, code_refs: named });
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
        revalidated_status(m.id, m.status.as_str())?;
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
        // Seen again with another hash: still stale since the first time, the hash updated; a change that is no transition.
        let rows2 = vec![RefRow { id: rows[0].id, code: stale.clone() }];
        let later = at() + chrono::Duration::hours(1);
        let ups2 = plan(&rows2, &[FileState::present("src/a.rs", "h3")], later);
        assert_eq!((ups2[0].now.as_ref().unwrap().stale_since, ups2[0].now.as_ref().unwrap().seen_hash.as_deref()), (Some(at()), Some("h3")));
        let seen = ups2[0].change.clone().unwrap();
        assert!(seen.seen_only && seen.seen_hash.as_deref() == Some("h3") && !seen.flagged && !seen.cleared && seen.moved_from.is_none());
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
        // The drop is reported as a move; and as cleared when the dropped reference was stale.
        let merged = of(3, "old.rs").unwrap().change.clone().unwrap();
        assert!(merged.path == "new.rs" && merged.moved_from.as_deref() == Some("old.rs") && !merged.cleared && !merged.flagged);
        let mut stale = rows[3].clone();
        (stale.code.stale_since, stale.code.seen_hash) = (Some(at()), Some("h7".into()));
        let ups = plan(&[rows[2].clone(), stale], &[FileState::renamed("old.rs", "new.rs", "h1")], at());
        assert!(ups.len() == 1 && ups[0].now.is_none() && ups[0].change.as_ref().is_some_and(|c| c.cleared && c.was_stale && c.path == "new.rs"), "{ups:?}");
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
        // A hash for a file last reported deleted: taken, and stale until the file is seen again.
        let deleted = revalidated(&stored, Some(&[CodeRef::new("b.rs", "h5")])).unwrap();
        assert_eq!((deleted[0].blob_hash.as_str(), deleted[0].stale_since, deleted[0].seen_hash.as_deref()), ("h5", Some(at()), None));
        assert!(revalidated(&stored, Some(&[CodeRef::new("zzz.rs", "h5")])).is_err());
        // A reference that is not stale: its own hash changes nothing, another is refused (the
        // file was seen at `h9` and back at `h1`, and a caller that checked `h9` confirms late).
        assert_eq!(revalidated(&stored, Some(&[CodeRef::new("c.rs", "h1")])).unwrap(), vec![CodeRef::new("c.rs", "h1")]);
        let late = revalidated(&stored, Some(&[CodeRef::new("c.rs", "h9")])).unwrap_err();
        assert_eq!(crate::error::code_of(&late), crate::error::ErrorCode::Conflict, "{late:#}");
        // The hash last seen, given: fresh. Another one: the file was seen with `h2` since,
        // so the reference takes the hash and stays stale.
        assert_eq!(revalidated(&stored, Some(&[CodeRef::new("a.rs", "h2")])).unwrap(), vec![CodeRef::new("a.rs", "h2")]);
        let kept = revalidated(&stored, Some(&[CodeRef::new("a.rs", "h1b")])).unwrap();
        assert_eq!((kept[0].blob_hash.as_str(), kept[0].stale_since, kept[0].seen_hash.as_deref()), ("h1b", Some(at()), Some("h2")));
    }

    #[test]
    fn a_revision_takes_its_references_from_the_state_it_is_stored_in() {
        let later = at() + chrono::Duration::hours(1);
        let mut seen = CodeRef::new("a.rs", "h1");
        (seen.stale_since, seen.seen_hash) = (Some(at()), Some("h2".into()));
        let mut gone = CodeRef::new("b.rs", "h1");
        gone.stale_since = Some(at());
        let predecessor = vec![seen.clone(), gone.clone(), CodeRef::new("c.rs", "h1")];
        // What a reviser reads: as last seen, without the deleted file.
        let read = inherited_refs(&predecessor);
        assert_eq!(read, vec![CodeRef::new("a.rs", "h2"), CodeRef::new("c.rs", "h1")]);
        // Stored with nothing seen in between: exactly that, fresh.
        assert_eq!(successor_refs(&read, true, &predecessor, later), read);
        // Seen in between: `a.rs` restored to `h1`, `c.rs` renamed with the same content, and a
        // file `d.rs` the reviser read deleted. The revision was written about `a.rs` at
        // `h2` and about `d.rs`: both start stale. The rename is followed.
        let mut d_gone = CodeRef::new("d.rs", "h4");
        d_gone.stale_since = Some(later);
        let now = vec![CodeRef::new("a.rs", "h1"), gone, d_gone, CodeRef::new("moved/c.rs", "h1")];
        let read = vec![CodeRef::new("a.rs", "h2"), CodeRef::new("c.rs", "h1"), CodeRef::new("d.rs", "h4")];
        let stored = successor_refs(&read, true, &now, later);
        let state: Vec<_> = stored.iter().map(|r| (r.path.as_str(), r.blob_hash.as_str(), r.stale_since, r.seen_hash.as_deref())).collect();
        assert_eq!(state, vec![("a.rs", "h2", Some(later), Some("h1")), ("d.rs", "h4", Some(later), None), ("moved/c.rs", "h1", None, None)]);
        // Renamed and changed in between: what the reviser read of it cannot be told, so the
        // reference keeps the predecessor's hash and starts stale.
        let mut moved = CodeRef::new("new/c.rs", "h1");
        (moved.stale_since, moved.seen_hash) = (Some(later), Some("h9".into()));
        let unknown = successor_refs(&[CodeRef::new("c.rs", "h1")], true, &[moved], later);
        assert_eq!((unknown[0].path.as_str(), unknown[0].blob_hash.as_str(), unknown[0].stale_since, unknown[0].seen_hash.as_deref()), ("new/c.rs", "h1", Some(later), Some("h9")));
        // Renamed and then deleted in between: the reviser read it as `c.rs`, so the reference
        // is kept, stale, at the path it was deleted under. One that was deleted before the
        // reviser read (`b.rs`, not among what was read) is still dropped.
        let mut renamed_gone = CodeRef::new("moved/c.rs", "h1");
        renamed_gone.stale_since = Some(later);
        let mut b_gone = CodeRef::new("b.rs", "h1");
        b_gone.stale_since = Some(at());
        let kept = successor_refs(&[CodeRef::new("c.rs", "h1")], true, &[b_gone.clone(), renamed_gone], later);
        assert_eq!(kept.len(), 1, "{kept:?}");
        assert_eq!((kept[0].path.as_str(), kept[0].blob_hash.as_str(), kept[0].stale_since, kept[0].seen_hash.as_deref()), ("moved/c.rs", "h1", Some(later), None));
        assert!(successor_refs(&[], true, &[b_gone], later).is_empty());
        // Its own: the hash last seen is fresh, another one is stale as the predecessor was,
        // and a path or a hash the predecessor never saw is the writer's statement.
        let own = successor_refs(&[CodeRef::new("a.rs", "h2"), CodeRef::new("new.rs", "n1")], false, &predecessor, later);
        assert_eq!(own, vec![CodeRef::new("a.rs", "h2"), CodeRef::new("new.rs", "n1")]);
        let old = successor_refs(&[CodeRef::new("a.rs", "h1"), CodeRef::new("b.rs", "h1")], false, &predecessor, later);
        assert_eq!((old[0].stale_since, old[0].seen_hash.as_deref(), old[1].stale_since, old[1].seen_hash.as_deref()), (Some(at()), Some("h2"), Some(at()), None));
    }

    #[test]
    fn reports_applied_in_order_to_a_copy() {
        let id = Uuid::from_u128(1);
        let refs = vec![CodeRef::new("a.rs", "A"), CodeRef::new("other.rs", "O")];
        // Changed and changed back in one request: as it was. Changed only: stale.
        assert_eq!(applied(id, &refs, &[FileState::present("a.rs", "B"), FileState::present("a.rs", "A")], at()), refs);
        let once = applied(id, &refs, &[FileState::present("a.rs", "B")], at());
        assert!(once[0].stale_since == Some(at()) && once[1] == refs[1]);
        assert_eq!(applied(id, &refs, &[FileState::renamed("a.rs", "b.rs", "A")], at())[0], CodeRef::new("b.rs", "A"));
    }

    #[test]
    fn stored_paths_in_canonical_form() {
        let (m, n) = (Uuid::from_u128(1), Uuid::from_u128(2));
        let rows: Vec<(Uuid, String)> =
            [(m, "./src//a.rs"), (m, "src/a.rs"), (m, "src\\b.rs"), (m, "./src/b.rs"), (m, "../x"), (n, "./src/a.rs"), (n, "ok.rs")].map(|(id, p)| (id, p.to_string())).to_vec();
        assert_eq!(
            canonical_paths(&rows),
            vec![
                // The canonical row is kept; of two that are not, the first by path.
                (m, "./src//a.rs".to_string(), None),
                (m, "./src/b.rs".to_string(), Some("src/b.rs".to_string())),
                (m, "src\\b.rs".to_string(), None),
                (n, "./src/a.rs".to_string(), Some("src/a.rs".to_string())),
            ]
        );
        // Counted, since nothing can be done with them: the path that leaves the repository.
        assert_eq!(uncanonical_paths(&rows), 1);
        assert_eq!(uncanonical_paths(&rows[..2]), 0);
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
