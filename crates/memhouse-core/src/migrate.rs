// SPDX-License-Identifier: Apache-2.0
//! Moving a whole installation from one store to another (TR-MIG-01, TR-MIG-03, PROF-02,
//! PROF-03): Lite to Standard, and back. Records travel in the canonical export form
//! ([`RecordLine`]) with their stored vectors beside them, so nothing is embedded again; the
//! tables around them (policies, identity, the deletion ledger, the queues, the audit log with
//! its hashes) travel row by row. After the copy every record is read back from the target and
//! its hash compared with the source's; only then is the migration recorded as complete.
//!
//! The source is only ever read. The target carries a marker from the first write, so a run that
//! was interrupted is resumed by running it again: what is there is kept, the rest is copied,
//! and everything is verified.

use crate::format::{RecordLine, SCHEMA_VERSION};
use crate::traits::Store;
use crate::types::{EmbeddingIdentity, ImportRow};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;
use uuid::Uuid;

/// The audit action of a finished migration, written on the target.
pub const AUDIT_ACTION: &str = "migration.complete";

/// The logical type of a column that travels (the two stores keep it in different physical types).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Col {
    Text,
    Int,
    Bool,
    /// Microseconds since the epoch in a row; `timestamptz` or an integer in the store.
    Time,
    /// A JSON document (`jsonb`, or JSON text).
    Json,
    /// A list of texts (`text[]`, or a JSON array as text).
    Texts,
    Uuid,
    /// A list of ids (`uuid[]`, or a JSON array as text).
    Uuids,
    /// Bytes, as lower-case hex in a row.
    Bytes,
}

/// One table that travels row by row. A row is a JSON object with exactly these columns.
#[derive(Debug)]
pub struct Table {
    /// The name in reports; the table is `mh_<name>` in both stores (TR-CORE-04).
    pub name: &'static str,
    pub cols: &'static [(&'static str, Col)],
    /// The columns a page is ordered and continued by.
    pub key: &'static [&'static str],
    /// The key is a number the store would otherwise assign: it is kept, so the order of events
    /// (the audit chain, the queue) is the source's.
    pub serial: bool,
}

use Col::*;

/// Every table besides the records, in the order they are written (a row's references first).
/// Left behind on purpose: the embedding cache and the extraction cache (rebuilt on use), recall
/// explanations (a record of past answers, pruned by retention) and idempotency keys (a repeat
/// of a request made before the migration is carried out again).
pub const TABLES: &[Table] = &[
    Table { name: "policy", cols: &[("version", Text), ("body", Json), ("created_at", Time)], key: &["version"], serial: false },
    Table {
        name: "principal",
        cols: &[
            ("id", Text),
            ("tenant", Text),
            ("kind", Text),
            ("name", Text),
            ("subjects", Texts),
            ("kinds", Texts),
            ("denied_labels", Texts),
            ("org", Text),
            ("team", Text),
            ("can_commit", Bool),
            ("act_as", Bool),
            ("disabled_at", Time),
            ("created_at", Time),
            ("created_by", Text),
        ],
        key: &["id"],
        serial: false,
    },
    // Only the hash of a key's secret is stored, and only that moves.
    Table {
        name: "api_key",
        cols: &[("id", Text), ("principal_id", Text), ("hash", Text), ("scopes", Texts), ("expires_at", Time), ("revoked_at", Time), ("created_at", Time), ("created_by", Text)],
        key: &["id"],
        serial: false,
    },
    // The secrets that sign agent tokens: tokens issued before the move still verify after it.
    Table { name: "signing_key", cols: &[("id", Text), ("secret", Bytes), ("created_at", Time), ("retired_at", Time)], key: &["id"], serial: false },
    Table {
        name: "policy_spec",
        cols: &[
            ("tenant", Text),
            ("version", Int),
            ("name", Text),
            ("spec", Json),
            ("spec_hash", Text),
            ("status", Text),
            ("note", Text),
            ("proposed_by", Text),
            ("proposed_at", Time),
            ("approved_by", Text),
            ("approved_at", Time),
        ],
        key: &["tenant", "version"],
        serial: false,
    },
    Table {
        name: "policy_activation",
        cols: &[("id", Int), ("tenant", Text), ("version", Int), ("compiled", Text), ("action", Text), ("by_whom", Text), ("at", Time)],
        key: &["id"],
        serial: true,
    },
    Table {
        name: "link",
        cols: &[("tenant", Text), ("subject", Text), ("linked_subject", Text), ("link_type", Text), ("memory_id", Uuid), ("created_by", Text), ("created_at", Time)],
        key: &["tenant", "subject", "linked_subject", "link_type"],
        serial: false,
    },
    Table {
        name: "grant",
        cols: &[
            ("id", Uuid),
            ("tenant", Text),
            ("grantor", Text),
            ("grantee", Text),
            ("subjects", Text),
            ("kinds", Texts),
            ("created_by", Text),
            ("created_at", Time),
            ("expires_at", Time),
            ("revoked_at", Time),
        ],
        key: &["id"],
        serial: false,
    },
    Table {
        name: "eval_suite",
        cols: &[("tenant", Text), ("name", Text), ("hash", Text), ("suite", Json), ("created_by", Text), ("created_at", Time)],
        key: &["tenant", "name"],
        serial: false,
    },
    Table {
        name: "eval_run",
        cols: &[("id", Uuid), ("tenant", Text), ("suite", Text), ("suite_hash", Text), ("policy_version", Text), ("trigger", Text), ("run", Json), ("created_at", Time)],
        key: &["id"],
        serial: false,
    },
    Table {
        name: "deletion_ledger",
        cols: &[("id", Int), ("at", Time), ("tenant", Text), ("subject", Text), ("memory_id", Uuid), ("scope", Text), ("actor", Text)],
        key: &["id"],
        serial: true,
    },
    // Queued work moves as it is: a proposal not yet through the pipeline runs on the target.
    Table {
        name: "intake",
        cols: &[
            ("seq", Int),
            ("id", Uuid),
            ("tenant", Text),
            ("subject", Text),
            ("record_ids", Uuids),
            ("agent", Text),
            ("acting_user", Text),
            ("source", Text),
            ("scope_agent", Text),
            ("scope_user", Text),
            ("status", Text),
            ("attempts", Int),
            ("run_after", Time),
            ("locked_until", Time),
            ("enqueued_at", Time),
            ("finished_at", Time),
            ("payload", Json),
            ("outcome", Json),
            ("error", Text),
            ("embedder", Text),
        ],
        key: &["seq"],
        serial: true,
    },
    Table {
        name: "enrich_job",
        cols: &[
            ("id", Int),
            ("tenant", Text),
            ("subject", Text),
            ("session_id", Text),
            ("round_ids", Uuids),
            ("status", Text),
            ("attempts", Int),
            ("run_after", Time),
            ("locked_until", Time),
            ("enqueued_at", Time),
            ("finished_at", Time),
            ("cache_key", Text),
            ("outcome", Json),
            ("error", Text),
        ],
        key: &["id"],
        serial: true,
    },
    // Last, and in order: every event with the hashes it was written with, so the chain verifies.
    Table {
        name: "audit",
        cols: &[
            ("id", Int),
            ("at", Time),
            ("actor", Text),
            ("action", Text),
            ("tenant", Text),
            ("subject", Text),
            ("memory_id", Uuid),
            ("detail", Text),
            ("prev_hash", Text),
            ("hash", Text),
        ],
        key: &["id"],
        serial: true,
    },
];

pub fn table(name: &str) -> anyhow::Result<&'static Table> {
    TABLES.iter().find(|t| t.name == name).ok_or_else(|| anyhow::anyhow!("no table named {name:?} takes part in a migration"))
}

/// The stored vectors of one record, as the store holds them.
#[derive(Debug, Clone, PartialEq)]
pub struct RecordVectors {
    pub id: Uuid,
    pub embedding: Option<Vec<f32>>,
    pub alt: Option<Vec<f32>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordCount {
    pub tenant: String,
    pub kind: String,
    pub status: String,
    pub records: u64,
}

/// Work in the queues. `leased` rows are claimed by a worker whose claim has not run out: a
/// server is using the database.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Queued {
    pub intake_pending: u64,
    pub intake_leased: u64,
    pub intake_dead: u64,
    pub enrich_pending: u64,
    pub enrich_leased: u64,
    /// Microseconds since the epoch at which the last claim runs out.
    pub leased_until: Option<i64>,
}

/// What a store holds, as far as a migration is concerned. Read-only, and safe on a database
/// that has no MemHouse schema yet (everything is empty then).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Summary {
    pub schema_version: Option<u32>,
    pub identity: Option<EmbeddingIdentity>,
    /// The target of an unfinished re-embedding.
    pub reembed_target: Option<EmbeddingIdentity>,
    /// Records by tenant, kind and state, in that order.
    pub records: Vec<RecordCount>,
    pub vectors: u64,
    pub second_vectors: u64,
    /// Rows of every table of [`TABLES`].
    pub tables: BTreeMap<String, u64>,
    /// Rows of the tables a migration leaves behind.
    pub left_behind: BTreeMap<String, u64>,
    pub queued: Queued,
    /// Records whose text or JSON holds a NUL character (Postgres stores none).
    pub nul_records: u64,
    /// The newest `updated_at` of any record, in microseconds.
    pub last_change: Option<i64>,
    /// Id and hash of the last audit event.
    pub audit_head: Option<(i64, String)>,
    /// The database's size as the store reports it.
    pub size_bytes: Option<u64>,
}

impl Summary {
    pub fn record_total(&self) -> u64 {
        self.records.iter().map(|r| r.records).sum()
    }

    pub fn tenants(&self) -> Vec<String> {
        let mut t: Vec<String> = self.records.iter().map(|r| r.tenant.clone()).collect();
        t.dedup();
        t
    }

    /// Nothing a migration would write is there yet.
    pub fn is_empty(&self) -> bool {
        self.record_total() == 0 && self.tables.values().all(|n| *n == 0)
    }

    /// What is in the target but not as in the source, by name.
    fn differences(&self, target: &Summary, extra_audit: u64) -> Vec<String> {
        let mut out = vec![];
        if self.records != target.records {
            out.push(format!("records by tenant, kind and state differ: {} in the source, {} in the target", self.record_total(), target.record_total()));
        }
        if (self.vectors, self.second_vectors) != (target.vectors, target.second_vectors) {
            out.push(format!("vectors differ: {} + {} second in the source, {} + {} in the target", self.vectors, self.second_vectors, target.vectors, target.second_vectors));
        }
        for t in TABLES {
            let (s, mut d) = (self.tables.get(t.name).copied().unwrap_or(0), target.tables.get(t.name).copied().unwrap_or(0));
            if t.name == "audit" {
                d = d.saturating_sub(extra_audit);
            }
            if s != d {
                out.push(format!("{}: {s} rows in the source, {d} in the target", t.name));
            }
        }
        out
    }
}

/// Something the operator should know before a migration. `blocking` stops it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Attention {
    pub blocking: bool,
    pub text: String,
}

impl Attention {
    pub fn stop(text: impl Into<String>) -> Attention {
        Attention { blocking: true, text: text.into() }
    }
    pub fn note(text: impl Into<String>) -> Attention {
        Attention { blocking: false, text: text.into() }
    }
}

/// Where the target stands with respect to this migration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetState {
    /// Nothing there: a first run.
    Empty,
    /// An earlier run of this migration stopped part-way: this run resumes it.
    Resume,
    /// This migration finished earlier.
    Complete,
    /// It holds something else.
    Occupied,
}

/// Told, in a sentence, what a migration is doing.
pub type Progress = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Clone)]
pub struct Options {
    /// The source and the target as they are named in messages, the marker and the audit event:
    /// never with credentials.
    pub source_label: String,
    pub target_label: String,
    /// The tenant the `migration.complete` event is written under.
    pub tenant: String,
    pub actor: String,
    /// Records per page.
    pub page: usize,
    /// Pages written to the target at once.
    pub writers: usize,
    /// The target cannot store a NUL character in text (Postgres).
    pub target_refuses_nul: bool,
    /// The largest vector the target can store, if it has a limit.
    pub target_max_dim: Option<usize>,
    /// Records read for the dry run's estimate.
    pub sample: usize,
    /// What the caller found on its own (a server that still has the source open, ...).
    pub extra: Vec<Attention>,
    pub progress: Option<Progress>,
}

impl Options {
    pub fn new(source_label: &str, target_label: &str, tenant: &str) -> Options {
        Options {
            source_label: source_label.into(),
            target_label: target_label.into(),
            tenant: tenant.into(),
            actor: "cli".into(),
            page: 1000,
            writers: 1,
            target_refuses_nul: false,
            target_max_dim: None,
            sample: 2000,
            extra: vec![],
            progress: None,
        }
    }

    fn say(&self, text: &str) {
        if let Some(p) = &self.progress {
            p(text);
        }
    }
}

/// What a dry run reports (TR-MIG-03). Nothing was changed to make it.
#[derive(Debug, Clone, Serialize)]
pub struct Plan {
    pub source: Summary,
    pub target: Summary,
    pub target_state: TargetState,
    pub attention: Vec<Attention>,
    /// (events, the first event whose hash does not follow) of the source's audit chain.
    pub source_audit: (u64, Option<i64>),
    /// Records read with their vectors and hashed, and the seconds it took.
    pub sample: Option<(u64, f64)>,
}

impl Plan {
    pub fn blocked(&self) -> bool {
        self.attention.iter().any(|a| a.blocking)
    }
}

/// The marker a migration leaves in its target.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Marker {
    pub source: String,
    pub identity: EmbeddingIdentity,
    /// `copying` or `complete`.
    pub state: String,
    pub started_at: chrono::DateTime<chrono::Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<chrono::DateTime<chrono::Utc>>,
    /// What the source held when the target was verified against it: a later run compares the
    /// source with this before it calls the migration complete.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verified: Option<SourceState>,
}

/// What a source held at one moment, as far as a migration can tell without reading every
/// record: counts, the newest change of a record, and the last audit event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceState {
    pub records: Vec<RecordCount>,
    pub vectors: u64,
    pub second_vectors: u64,
    pub tables: BTreeMap<String, u64>,
    pub last_change: Option<i64>,
    pub audit_head: Option<(i64, String)>,
    /// A digest of the rows of every table of [`DIGESTED`]: a row whose contents changed in
    /// place (a queued job that failed, a key that was revoked) changes no count and may write
    /// no audit event. Empty in the figures taken from a summary alone, and in a marker written
    /// before digests were recorded, which therefore never equals a state that was read.
    #[serde(default)]
    pub digests: BTreeMap<String, TableDigest>,
}

/// The tables whose rows are digested for a [`SourceState`]: every table that moves row by row
/// but the audit log, which only grows and whose last event (id and hash) covers every row
/// before it. Records are covered by their counts and their newest change time.
fn digested() -> impl Iterator<Item = &'static Table> {
    TABLES.iter().filter(|t| t.name != "audit")
}

impl SourceState {
    /// The figures of a summary, without the digests: for comparing two summaries.
    pub fn of(s: &Summary) -> SourceState {
        SourceState {
            records: s.records.clone(),
            vectors: s.vectors,
            second_vectors: s.second_vectors,
            tables: s.tables.clone(),
            last_change: s.last_change,
            audit_head: s.audit_head.clone(),
            digests: BTreeMap::new(),
        }
    }

    /// What the store holds now: its summary, and a digest of every row of the digested tables.
    pub async fn read(store: &dyn Store, page: usize) -> anyhow::Result<SourceState> {
        let mut state = SourceState::of(&store.migration_summary().await?);
        for t in digested() {
            let mut d = TableDigest::default();
            let mut after = None;
            loop {
                let rows = store.migration_dump(t.name, after.as_ref(), page).await?;
                let Some(last) = rows.last().cloned() else { break };
                rows.iter().for_each(|row| d.add(row));
                after = Some(last);
            }
            state.digests.insert(t.name.into(), d);
        }
        Ok(state)
    }
}

/// Fails when the source no longer holds what it held at `then`: something wrote to it.
pub async fn ensure_source_unchanged(source: &dyn Store, then: &SourceState, when: &str) -> anyhow::Result<()> {
    let now = SourceState::read(source, 1000).await?;
    anyhow::ensure!(
        now == *then,
        "the source changed {when} (a server or an agent is still writing to it): what was written is not in the target. \
         Stop them, and migrate again into a new, empty target"
    );
    Ok(())
}

/// The sha256 of a record's canonical export line: what "the same record" means (TR-MIG-01).
pub fn record_hash(r: &RecordLine) -> [u8; 32] {
    // The line as `Line::Record(..).to_canonical()` writes it (a test holds the two together),
    // without copying the record to build one: this runs once or twice for every record moved.
    let fields = serde_json::to_string(r).expect("records always serialize");
    let mut h = Sha256::new();
    h.update(b"{\"type\":\"record\",");
    h.update(&fields.as_bytes()[1..]);
    h.finalize().into()
}

/// A JSON value with every number in one spelling. `jsonb` writes the float 1e16 as the integer
/// 10000000000000000: the same number, another text.
fn numbers_normalized(v: &serde_json::Value) -> serde_json::Value {
    use serde_json::Value;
    match v {
        Value::Number(n) if !n.is_i64() && !n.is_u64() => match n.as_f64() {
            Some(x) if x.fract() == 0.0 && x.abs() < 1.8e19 => {
                if x < 0.0 {
                    Value::from(x as i64)
                } else {
                    Value::from(x as u64)
                }
            }
            _ => v.clone(),
        },
        Value::Array(a) => Value::Array(a.iter().map(numbers_normalized).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), numbers_normalized(x))).collect()),
        _ => v.clone(),
    }
}

/// The top-level fields in which two records differ, and whether they are equal once numbers
/// are spelled one way.
fn record_difference(a: &RecordLine, b: &RecordLine) -> (Vec<String>, bool) {
    let (a, b) = (serde_json::to_value(a).unwrap_or_default(), serde_json::to_value(b).unwrap_or_default());
    let mut fields = vec![];
    let empty = serde_json::Map::new();
    let (ao, bo) = (a.as_object().unwrap_or(&empty), b.as_object().unwrap_or(&empty));
    for k in ao.keys().chain(bo.keys().filter(|k| !ao.contains_key(*k))) {
        if ao.get(k) != bo.get(k) {
            fields.push(k.clone());
        }
    }
    (fields, numbers_normalized(&a) == numbers_normalized(&b))
}

/// An order-independent digest of a table's rows (the two stores order text keys differently).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableDigest {
    pub rows: u64,
    /// The sha256 of every row, combined by exclusive or.
    #[serde(serialize_with = "hex_of", deserialize_with = "of_hex")]
    pub xor: [u8; 32],
}

fn hex_of<S: serde::Serializer>(bytes: &[u8; 32], s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&hex::encode(bytes))
}

fn of_hex<'de, D: serde::Deserializer<'de>>(d: D) -> Result<[u8; 32], D::Error> {
    let text = String::deserialize(d)?;
    hex::decode(&text).ok().and_then(|b| b.try_into().ok()).ok_or_else(|| serde::de::Error::custom("a digest is 64 hex digits"))
}

impl TableDigest {
    fn add(&mut self, row: &serde_json::Value) {
        let h: [u8; 32] = Sha256::digest(numbers_normalized(row).to_string().as_bytes()).into();
        for (x, y) in self.xor.iter_mut().zip(h) {
            *x ^= y;
        }
        self.rows += 1;
    }
}

/// The id just before `id`, so a page "after" it starts at `id`.
fn before(id: Uuid) -> Option<Uuid> {
    id.as_u128().checked_sub(1).map(Uuid::from_u128)
}

async fn marker_of(store: &dyn Store) -> anyhow::Result<Option<Marker>> {
    Ok(match store.migration_marker().await? {
        Some(v) => Some(serde_json::from_value(v).map_err(|e| anyhow::anyhow!("the target holds a migration marker this build cannot read: {e}"))?),
        None => None,
    })
}

/// Look at both stores and say what a migration would do and what stands in its way. Reads only.
/// `target` is `None` when there is nothing there yet (a database file that does not exist).
pub async fn inspect(source: &dyn Store, target: Option<&dyn Store>, o: &Options, measure: bool) -> anyhow::Result<Plan> {
    let s = source.migration_summary().await?;
    let mut attention = vec![];
    let identity = s.identity.clone();
    match s.schema_version {
        None => attention.push(Attention::stop(format!("{} is not a MemHouse database (it records no schema version)", o.source_label))),
        Some(v) if v != SCHEMA_VERSION => attention.push(Attention::stop(format!(
            "the source is at schema version {v} and this build migrates version {SCHEMA_VERSION}: start MemHouse once on the source with this build to upgrade it, then run the migration"
        ))),
        _ => {}
    }
    if identity.is_none() && s.schema_version.is_some() {
        attention.push(Attention::stop("the source does not record which embedding model made its vectors".to_string()));
    }
    if let Some(t) = &s.reembed_target {
        attention.push(Attention::stop(format!(
            "an unfinished re-embedding to {t}: its vectors would not move. Finish it with `memhouse reembed`, or drop it with `memhouse reembed --abort`, then run the migration"
        )));
    }
    let q = &s.queued;
    if q.intake_leased + q.enrich_leased > 0 {
        let until = q.leased_until.and_then(chrono::DateTime::from_timestamp_micros).map(|t| t.format(" until %H:%M:%S UTC").to_string()).unwrap_or_default();
        attention.push(Attention::stop(format!(
            "{} queued writes and {} enrichment jobs are being worked on right now (claimed{until}): a server is using the source. \
             Stop `memhouse serve` and the agents writing to it, wait for the claims to run out, and run the migration again",
            q.intake_leased, q.enrich_leased
        )));
    }
    if q.intake_pending + q.enrich_pending > 0 {
        attention.push(Attention::note(format!(
            "{} queued writes and {} enrichment jobs are not finished: they move as they are, and the server works through them on the target",
            q.intake_pending, q.enrich_pending
        )));
    }
    if q.intake_dead > 0 {
        attention.push(Attention::note(format!("{} writes that failed for good are set aside in the queue: they move with it", q.intake_dead)));
    }
    if s.nul_records > 0 && o.target_refuses_nul {
        attention
            .push(Attention::stop(format!("{} records hold a NUL character in their text or metadata, which Postgres cannot store: revise or delete them first", s.nul_records)));
    }
    if let (Some(id), Some(max)) = (&identity, o.target_max_dim) {
        if id.dim > max {
            attention.push(Attention::stop(format!("the vectors have {} dimensions and the target stores at most {max}", id.dim)));
        }
    }
    let source_audit = source.audit_verify().await?;
    if let Some(id) = source_audit.1 {
        attention.push(Attention::note(format!("the source's audit chain is broken at event {id}: it is copied as it is, and is broken at the same event on the target")));
    }

    let (t, marker) = match target {
        Some(t) => (t.migration_summary().await?, marker_of(t).await?),
        None => (Summary::default(), None),
    };
    let ours = marker.as_ref().filter(|m| m.source == o.source_label && Some(&m.identity) == identity.as_ref());
    let target_state = match (ours, t.is_empty()) {
        (Some(m), _) if m.state == "complete" => TargetState::Complete,
        (Some(_), _) => TargetState::Resume,
        (None, true) if marker.is_none() => TargetState::Empty,
        _ => TargetState::Occupied,
    };
    match target_state {
        TargetState::Occupied => attention.push(Attention::stop(match &marker {
            Some(m) => format!("the target holds a migration from {} (state: {}), not from this source: use an empty database", m.source, m.state),
            None => format!(
                "the target already holds data ({} records, {} audit events): `memhouse migrate` only fills an empty database. Create a new one, or remove what is there",
                t.record_total(),
                t.tables.get("audit").copied().unwrap_or(0)
            ),
        })),
        TargetState::Resume => attention.push(Attention::note(format!(
            "an earlier run of this migration stopped part-way ({} of {} records are in the target): this run resumes it, and verifies everything",
            t.record_total(),
            s.record_total()
        ))),
        // Complete as of then: only if the source still is what the target was verified against.
        TargetState::Complete if ours.and_then(|m| m.verified.as_ref()) == Some(&SourceState::read(source, o.page).await?) => {
            attention.push(Attention::note("this migration already completed: there is nothing left to copy".to_string()))
        }
        TargetState::Complete => attention.push(Attention::stop(
            "this migration completed earlier, and the source has changed since: the target does not hold what was written to the source after it. \
             Nothing is switched over. Migrate again into a new, empty target (or, if the target is the database in use now, leave the source alone)"
                .to_string(),
        )),
        TargetState::Empty => {}
    }
    if let (Some(a), Some(b)) = (&identity, &t.identity) {
        if a != b && target_state != TargetState::Occupied {
            attention.push(Attention::stop(format!("the target's vectors are made with {b}, the source's with {a}")));
        }
    }
    if t.schema_version.is_some_and(|v| v > SCHEMA_VERSION) {
        attention.push(Attention::stop("the target was written by a newer MemHouse than this build".to_string()));
    }
    attention.extend(o.extra.iter().cloned());

    // The read half of the work, on a sample: records with their vectors, hashed.
    let mut sample = None;
    if measure && o.sample > 0 {
        let started = Instant::now();
        let mut n = 0u64;
        'tenants: for tenant in s.tenants() {
            let mut after = None;
            loop {
                let left = o.sample.saturating_sub(n as usize);
                if left == 0 {
                    break 'tenants;
                }
                let page = source.export_records(&tenant, None, after, left.min(o.page)).await?;
                let Some(last) = page.last() else { break };
                after = Some(last.id);
                let ids: Vec<Uuid> = page.iter().map(|r| r.id).collect();
                source.export_vectors(&tenant, &ids).await?;
                for r in &page {
                    record_hash(r);
                }
                n += page.len() as u64;
            }
        }
        if n > 0 {
            sample = Some((n, started.elapsed().as_secs_f64()));
        }
    }
    Ok(Plan { source: s, target: t, target_state, attention, source_audit, sample })
}

/// Two stored vectors of one record: the largest difference of a component, and whether they
/// are the same vector as far as recall is concerned (the same direction: cosine is all it uses).
/// Half precision moves a component by up to one part in two thousand; a store may also scale
/// a vector whose components it cannot hold. `None` when one side has a vector the other lacks.
fn vector_gap(a: &Option<Vec<f32>>, b: &Option<Vec<f32>>) -> Option<(f32, bool)> {
    match (a, b) {
        (None, None) => Some((0.0, true)),
        (Some(a), Some(b)) if a.len() == b.len() => {
            let gap = a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max);
            let (dot, na, nb) = a.iter().zip(b).fold((0f64, 0f64, 0f64), |(d, x2, y2), (x, y)| (d + (*x as f64) * (*y as f64), x2 + (*x as f64).powi(2), y2 + (*y as f64).powi(2)));
            let same = if na == 0.0 || nb == 0.0 { na == nb } else { dot / (na.sqrt() * nb.sqrt()) > 0.9999 };
            Some((gap, same))
        }
        _ => None,
    }
}

/// What a verification found wrong. The migration stops there: the target is not marked
/// complete, and the caller switches nothing over.
#[derive(Debug, Clone)]
pub struct VerificationFailed {
    pub problems: Vec<String>,
}

impl std::fmt::Display for VerificationFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the migration did not verify: {}", self.problems.join("; "))
    }
}

impl std::error::Error for VerificationFailed {}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    /// What the source held when the target was verified against it (in this run, or in the
    /// earlier one that completed): what the source must still hold when anything is switched.
    pub verified: Option<SourceState>,
    /// False when the migration had completed in an earlier run and nothing was done now.
    pub ran: bool,
    pub resumed: bool,
    pub records: u64,
    /// Records this run wrote (fewer than `records` on a resume).
    pub records_written: u64,
    pub tables: BTreeMap<String, u64>,
    pub source: Summary,
    pub copy_secs: f64,
    pub verify_secs: f64,
    /// Records whose JSON numbers the target spells differently (equal in value); ids of the first few.
    pub respelled: u64,
    pub respelled_ids: Vec<Uuid>,
    /// Vectors of a sample compared between the stores, and the largest difference of a component.
    pub vectors_compared: u64,
    pub vector_max_gap: f32,
    pub audit_events: u64,
    pub audit_broken_at: Option<i64>,
}

const NAMED: usize = 20;

/// Copy everything from `source` to `target`, verify it, and record the migration on the target.
/// Fails without marking the target complete when anything does not verify.
pub async fn run(source: Arc<dyn Store>, target: Arc<dyn Store>, o: &Options) -> anyhow::Result<Report> {
    let plan = inspect(source.as_ref(), Some(target.as_ref()), o, false).await?;
    let blocking: Vec<&str> = plan.attention.iter().filter(|a| a.blocking).map(|a| a.text.as_str()).collect();
    anyhow::ensure!(blocking.is_empty(), "the migration cannot start: {}", blocking.join("; "));
    let before_copy = plan.source;
    let identity = before_copy.identity.clone().ok_or_else(|| anyhow::anyhow!("the source records no embedding identity"))?;
    let mut report = Report {
        verified: None,
        ran: false,
        resumed: plan.target_state == TargetState::Resume,
        records: before_copy.record_total(),
        records_written: 0,
        tables: before_copy.tables.clone(),
        source: before_copy.clone(),
        copy_secs: 0.0,
        verify_secs: 0.0,
        respelled: 0,
        respelled_ids: vec![],
        vectors_compared: 0,
        vector_max_gap: 0.0,
        audit_events: plan.source_audit.0,
        audit_broken_at: plan.source_audit.1,
    };
    if plan.target_state == TargetState::Complete {
        // `inspect` has just read the source and found it equal to what the marker records.
        report.verified = marker_of(target.as_ref()).await?.and_then(|m| m.verified);
        return Ok(report);
    }
    report.ran = true;

    // The same identity as the source: its vectors are written as they are.
    target.migrate(identity.dim, &identity.embedder).await?;
    let theirs = target.embedding_identity().await?.0;
    anyhow::ensure!(theirs.as_ref() == Some(&identity), "the target was not set up for the source's vectors ({identity}): it says {theirs:?}");
    let mut marker = match marker_of(target.as_ref()).await? {
        Some(m) => m,
        None => Marker { source: o.source_label.clone(), identity: identity.clone(), state: "copying".into(), started_at: chrono::Utc::now(), completed_at: None, verified: None },
    };
    target.set_migration_marker(&serde_json::to_value(&marker)?).await?;

    let started = Instant::now();
    let mut digests: BTreeMap<&'static str, TableDigest> = BTreeMap::new();
    // What records refer to, then the records, then what refers to them; the audit log last.
    let (first, rest): (Vec<&Table>, Vec<&Table>) =
        TABLES.iter().partition(|t| matches!(t.name, "policy" | "principal" | "api_key" | "signing_key" | "policy_spec" | "policy_activation"));
    for t in first {
        digests.insert(t.name, copy_table(source.as_ref(), target.as_ref(), t, o).await?);
    }
    let mut hashes: BTreeMap<String, Vec<(Uuid, [u8; 32])>> = BTreeMap::new();
    let total = before_copy.record_total();
    let mut done = 0u64;
    for tenant in before_copy.tenants() {
        let h = copy_records(&source, &target, &tenant, o, total, &mut done, &mut report.records_written).await?;
        hashes.insert(tenant, h);
    }
    o.say(&format!("records: {total} copied in {:.1} s", started.elapsed().as_secs_f64()));
    for t in rest {
        digests.insert(t.name, copy_table(source.as_ref(), target.as_ref(), t, o).await?);
    }
    target.migration_loaded().await?;
    report.copy_secs = started.elapsed().as_secs_f64();
    o.say(&format!("everything copied in {:.1} s", report.copy_secs));

    // Verification (TR-MIG-01): every record read back from the target in its export form.
    let started = Instant::now();
    o.say("verifying");
    let mut problems: Vec<String> = vec![];
    let after_copy = source.migration_summary().await?;
    if SourceState::of(&after_copy) != SourceState::of(&before_copy) {
        problems.push("the source changed while it was being copied (a server or an agent is still writing to it): stop them and run the migration again".into());
    }
    let (mut differing, mut missing, mut unexpected) = (vec![], vec![], vec![]);
    let (mut n_differing, mut n_missing, mut n_unexpected, mut vectors_off) = (0u64, 0u64, 0u64, 0u64);
    for (tenant, expected) in &hashes {
        let mut at = 0usize;
        let mut after = None;
        let mut pages = 0u64;
        loop {
            let page = target.export_records(tenant, None, after, o.page).await?;
            let Some(last) = page.last() else { break };
            after = Some(last.id);
            // A sample of the vectors: the first page of each tenant and every twentieth after.
            if pages % 20 == 0 {
                let ids: Vec<Uuid> = page.iter().map(|r| r.id).collect();
                let theirs = target.export_vectors(tenant, &ids).await?;
                let ours: BTreeMap<Uuid, RecordVectors> = source.export_vectors(tenant, &ids).await?.into_iter().map(|v| (v.id, v)).collect();
                for v in &theirs {
                    let pairs = ours.get(&v.id).map(|s| [vector_gap(&s.embedding, &v.embedding), vector_gap(&s.alt, &v.alt)]);
                    for pair in pairs.unwrap_or([None, None]) {
                        match pair {
                            Some((gap, true)) => report.vector_max_gap = report.vector_max_gap.max(gap),
                            _ => vectors_off += 1,
                        }
                    }
                    report.vectors_compared += v.embedding.is_some() as u64 + v.alt.is_some() as u64;
                }
            }
            pages += 1;
            for r in &page {
                // Both sides are in id order: what the target lacks is passed over, what it has
                // beyond the source is in between.
                while at < expected.len() && expected[at].0 < r.id {
                    n_missing += 1;
                    if missing.len() < NAMED {
                        missing.push(expected[at].0);
                    }
                    at += 1;
                }
                if at >= expected.len() || expected[at].0 != r.id {
                    n_unexpected += 1;
                    if unexpected.len() < NAMED {
                        unexpected.push(r.id);
                    }
                    continue;
                }
                if expected[at].1 != record_hash(r) {
                    // Read the source's record again to say what differs.
                    let theirs = source.export_records(tenant, None, before(r.id), 1).await?.into_iter().find(|s| s.id == r.id);
                    let (fields, same_value) = match &theirs {
                        Some(s) => record_difference(s, r),
                        None => (vec!["(the record is gone from the source)".into()], false),
                    };
                    if same_value {
                        report.respelled += 1;
                        if report.respelled_ids.len() < NAMED {
                            report.respelled_ids.push(r.id);
                        }
                    } else {
                        n_differing += 1;
                        if differing.len() < NAMED {
                            differing.push(format!("{} ({})", r.id, fields.join(", ")));
                        }
                    }
                }
                at += 1;
            }
        }
        n_missing += (expected.len() - at) as u64;
        missing.extend(expected[at..].iter().take(NAMED.saturating_sub(missing.len())).map(|e| e.0));
    }
    let list = |ids: &[Uuid]| ids.iter().map(Uuid::to_string).collect::<Vec<_>>().join(", ");
    if n_differing > 0 {
        problems.push(format!("{n_differing} records differ from the source; the first {} with the fields that differ: {}", differing.len(), differing.join(", ")));
    }
    if n_missing > 0 {
        problems.push(format!("{n_missing} records are missing from the target; the first {}: {}", missing.len(), list(&missing)));
    }
    if n_unexpected > 0 {
        problems.push(format!("{n_unexpected} records are in the target and not in the source; the first {}: {}", unexpected.len(), list(&unexpected)));
    }
    o.say(&format!("records: read back and compared in {:.1} s", started.elapsed().as_secs_f64()));
    if vectors_off > 0 {
        problems.push(format!("{vectors_off} vectors of the sample are not the source's (missing, of another size, or pointing elsewhere)"));
    }
    // The other tables, row for row.
    for t in TABLES {
        let mut d = TableDigest::default();
        let mut after = None;
        loop {
            let page = target.migration_dump(t.name, after.as_ref(), o.page).await?;
            let Some(last) = page.last().cloned() else { break };
            for row in &page {
                // An earlier run of this migration may have recorded its completion already.
                if t.name == "audit" && row["action"] == AUDIT_ACTION && row["id"].as_i64() > before_copy.audit_head.as_ref().map(|h| h.0) {
                    continue;
                }
                d.add(row);
            }
            after = Some(last);
        }
        if digests.get(t.name) != Some(&d) {
            problems.push(format!("the rows of {} differ between the source ({}) and the target ({})", t.name, digests.get(t.name).map_or(0, |s| s.rows), d.rows));
        }
    }
    o.say(&format!("tables: compared row for row, {:.1} s into the verification", started.elapsed().as_secs_f64()));
    let after_migration = target.migration_summary().await?;
    let recorded = after_migration.tables.get("audit").copied().unwrap_or(0).saturating_sub(digests.get("audit").map_or(0, |d| d.rows));
    problems.extend(before_copy.differences(&after_migration, recorded));
    let (events, broken) = target.audit_verify().await?;
    if broken != plan.source_audit.1 || events.saturating_sub(recorded) != plan.source_audit.0 && broken.is_none() {
        problems.push(match broken {
            Some(id) => format!("the audit chain does not verify on the target: broken at event {id}"),
            None => format!("the target's audit chain has {events} events, the source's {}", plan.source_audit.0),
        });
    }
    // Once more, now that the target has been read back: a write made during the verification
    // is as missing from the target as one made during the copy.
    // The rows are read again and digested: a row changed in place since it was copied (a
    // queued job that failed) moves no count and may write no audit event.
    let mut verified = SourceState::of(&before_copy);
    verified.digests = digested().map(|t| (t.name.to_string(), digests.get(t.name).cloned().unwrap_or_default())).collect();
    if problems.is_empty() && SourceState::read(source.as_ref(), o.page).await? != verified {
        problems.push("the source changed while the copy was being verified (a server or an agent is still writing to it): stop them and run the migration again".into());
    }
    report.verify_secs = started.elapsed().as_secs_f64();
    if !problems.is_empty() {
        return Err(VerificationFailed { problems }.into());
    }

    // Recorded on the target, once (TR-MIG-01); the source is never written to.
    if recorded == 0 {
        let detail = serde_json::json!({
            "source": o.source_label,
            "target": o.target_label,
            "embedding": identity,
            "records": report.records,
            "vectors": before_copy.vectors + before_copy.second_vectors,
            "tables": report.tables,
            "verification": {
                "records_compared": report.records,
                "records_differing": 0,
                "records_respelled": report.respelled,
                "vectors_compared": report.vectors_compared,
                "audit_events": report.audit_events,
                "audit_chain": if report.audit_broken_at.is_none() { "intact" } else { "as broken as the source's" },
            },
            "resumed": report.resumed,
            "copy_secs": (report.copy_secs * 10.0).round() / 10.0,
            "verify_secs": (report.verify_secs * 10.0).round() / 10.0,
        });
        target.audit(&o.actor, AUDIT_ACTION, &o.tenant, None, None, detail).await?;
    }
    marker.verified = Some(verified.clone());
    report.verified = Some(verified);
    marker.state = "complete".into();
    marker.completed_at = Some(chrono::Utc::now());
    target.set_migration_marker(&serde_json::to_value(&marker)?).await?;
    Ok(report)
}

/// Copy one table page by page. Returns the digest of the source's rows.
async fn copy_table(source: &dyn Store, target: &dyn Store, t: &'static Table, o: &Options) -> anyhow::Result<TableDigest> {
    let mut d = TableDigest::default();
    let mut after = None;
    loop {
        let page = source.migration_dump(t.name, after.as_ref(), o.page).await?;
        let Some(last) = page.last().cloned() else { break };
        for row in &page {
            d.add(row);
        }
        target.migration_load(t.name, &page).await.map_err(|e| e.context(format!("writing {} rows to the target", t.name)))?;
        after = Some(last);
        if d.rows % 50_000 < page.len() as u64 && d.rows >= 50_000 {
            o.say(&format!("{}: {} rows", t.name, d.rows));
        }
    }
    Ok(d)
}

/// Copy a tenant's records with their vectors. Returns (id, hash) of each, in id order.
async fn copy_records(
    source: &Arc<dyn Store>,
    target: &Arc<dyn Store>,
    tenant: &str,
    o: &Options,
    total: u64,
    done: &mut u64,
    written: &mut u64,
) -> anyhow::Result<Vec<(Uuid, [u8; 32])>> {
    use futures::stream::{FuturesUnordered, StreamExt};
    let mut hashes = vec![];
    let mut after = None;
    let mut writing = FuturesUnordered::new();
    let mut last_said = Instant::now();
    loop {
        let page = source.export_records(tenant, None, after, o.page).await?;
        let Some(last) = page.last() else { break };
        after = Some(last.id);
        let ids: Vec<Uuid> = page.iter().map(|r| r.id).collect();
        let mut vectors: BTreeMap<Uuid, RecordVectors> = source.export_vectors(tenant, &ids).await?.into_iter().map(|v| (v.id, v)).collect();
        let mut rows = Vec::with_capacity(page.len());
        for record in page {
            hashes.push((record.id, record_hash(&record)));
            let v = vectors.remove(&record.id);
            let (embedding, alt) = v.map(|v| (v.embedding, v.alt)).unwrap_or_default();
            // A second vector travels under the record's own key for it.
            let alt = alt.zip(record.alt_hash.clone()).map(|(v, h)| (h, v));
            rows.push(ImportRow { record, embedding, alt });
        }
        *done += rows.len() as u64;
        let target = target.clone();
        writing.push(tokio::spawn(async move { write_page(target.as_ref(), rows).await }));
        while writing.len() >= o.writers.max(1) {
            if let Some(r) = writing.next().await {
                *written += r??;
            }
        }
        if last_said.elapsed().as_secs() >= 5 {
            last_said = Instant::now();
            o.say(&format!("records: {done} of {total}"));
        }
    }
    while let Some(r) = writing.next().await {
        *written += r??;
    }
    Ok(hashes)
}

/// Write one page; when the store refuses it, find the record it refuses and name it.
async fn write_page(target: &dyn Store, rows: Vec<ImportRow>) -> anyhow::Result<u64> {
    match target.import_records(&rows).await {
        Ok(n) => Ok(n),
        Err(whole) => {
            for row in &rows {
                if let Err(e) = target.import_records(std::slice::from_ref(row)).await {
                    return Err(e.context(format!("the target refused record {} of tenant {}", row.record.id, row.record.tenant)));
                }
            }
            // Each went in alone: the failure was of the moment, and the page is written now.
            tracing::warn!("a page of records was written one by one after: {whole:#}");
            Ok(rows.len() as u64)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format::Line;

    #[test]
    fn numbers_are_compared_by_value() {
        let a = serde_json::json!({ "n": 1e16, "x": [1.5, 2.0], "s": "1e16" });
        let b = serde_json::json!({ "n": 10000000000000000u64, "x": [1.5, 2], "s": "1e16" });
        assert_ne!(a, b);
        assert_eq!(numbers_normalized(&a), numbers_normalized(&b));
        assert_ne!(numbers_normalized(&a), numbers_normalized(&serde_json::json!({ "n": 1e16, "x": [1.5, 2.5], "s": "1e16" })));
    }

    #[test]
    fn tables_are_well_formed() {
        for t in TABLES {
            assert!(t.key.iter().all(|k| t.cols.iter().any(|(c, _)| c == k)), "{}: a key column is not a column", t.name);
            assert!(!t.serial || (t.key.len() == 1 && t.cols.iter().any(|(c, ty)| *c == t.key[0] && *ty == Col::Int)), "{}: a serial key is one integer", t.name);
        }
        assert_eq!(TABLES.last().map(|t| t.name), Some("audit"), "the audit log is written last");
        assert!(table("audit").is_ok() && table("embed_cache").is_err());
    }

    #[test]
    fn vectors_are_the_same_when_they_point_the_same_way() {
        let v = Some(vec![0.6f32, -0.8, 0.0]);
        assert_eq!(vector_gap(&v, &v), Some((0.0, true)));
        assert_eq!(vector_gap(&None, &None), Some((0.0, true)));
        // Rounded as half precision rounds, or scaled as a whole: the same direction.
        assert!(matches!(vector_gap(&v, &Some(vec![0.6001, -0.7998, 0.0])), Some((g, true)) if g > 0.0 && g < 3e-4));
        assert!(matches!(vector_gap(&Some(vec![300_000.0, -400_000.0]), &Some(vec![0.75, -1.0])), Some((_, true))));
        // Another vector, another size, or none.
        assert!(matches!(vector_gap(&v, &Some(vec![0.8, 0.6, 0.0])), Some((_, false))));
        assert_eq!(vector_gap(&v, &Some(vec![0.6, -0.8])), None);
        assert_eq!(vector_gap(&v, &None), None);
    }

    #[test]
    fn a_record_hash_is_the_hash_of_its_export_line() {
        let text = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../memory-format/vectors/v2-full.jsonl")).unwrap();
        let mut seen = 0;
        for line in text.lines().skip(1) {
            if let Ok(Line::Record(r)) = crate::format::parse_line(line) {
                let canonical = Line::Record(r.clone()).to_canonical();
                assert_eq!(canonical, line);
                assert_eq!(record_hash(&r), <[u8; 32]>::from(Sha256::digest(canonical.as_bytes())));
                seen += 1;
            }
        }
        assert!(seen > 0, "the vector file holds records");
    }

    #[test]
    fn the_id_before() {
        assert_eq!(before(Uuid::from_u128(5)), Some(Uuid::from_u128(4)));
        assert_eq!(before(Uuid::nil()), None);
    }
}
