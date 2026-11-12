// SPDX-License-Identifier: Apache-2.0
//! MemHouse Memory Format v2 (TR-CORE-03, INT-10, PROF-02): the canonical, line-delimited export
//! of a tenant. One JSON object per line: a header, then `policy`, `record` and `link` lines.
//! Specification: `docs/memory-format.md`; conformance vectors: `memory-format/vectors/`.
//!
//! Lines are written in a canonical form (fields in a fixed order, empty optional fields left
//! out, JSON object keys sorted), so export → import → export reproduces every line byte for byte.

use crate::engine::{content_hash, Engine};
use crate::reembed::recover_focus;
use crate::types::*;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use uuid::Uuid;

pub const FORMAT: &str = "memhouse.memory";
/// The format version this build writes. Version 1 files (before schema v2) are still read.
pub const VERSION: u32 = 2;
/// The logical schema version (TR-CORE-04, `docs/schema.md`), recorded by every store.
pub const SCHEMA_VERSION: u32 = 7;
/// Policy version given to records written before policies were recorded.
pub const LEGACY_POLICY: &str = "legacy-v1";

/// First line of a file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Header {
    pub format: String,
    pub version: u32,
    pub schema_version: u32,
    pub producer: String,
    pub exported_at: DateTime<Utc>,
    pub tenant: String,
    /// Set when the export holds one subject only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    /// What the source database's vectors were made with. Vectors are not exported: an import
    /// embeds every record with its own configured model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedder: Option<EmbeddingIdentity>,
}

/// A compiled policy that admitted records (`provenance.policy_version` refers to it).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PolicyLine {
    pub version: String,
    /// The policy as compiled: governance settings, and the access-decision values (D-01…D-07)
    /// once G08 records them.
    pub body: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

/// One logical record with every representation that travels: text, structured form and code
/// references share its id (HYB-04). Vectors are derived again on import.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordLine {
    pub id: Uuid,
    pub tenant: String,
    pub subject: String,
    pub kind: MemoryKind,
    pub status: MemoryStatus,
    pub content: String,
    /// Deduplication key (sha256 hex).
    pub content_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub occurred_at: Option<DateTime<Utc>>,
    pub valid_from: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub valid_to: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supersedes: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded_by: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Scope::is_empty")]
    pub scope: Scope,
    pub source: String,
    pub confidence: f32,
    #[serde(default, skip_serializing_if = "Provenance::is_empty")]
    pub provenance: Provenance,
    /// Cache key of the round's second, user-only vector; its text is recovered from `content`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alt_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub structured: Option<Structured>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub code_refs: Vec<CodeRef>,
    #[serde(default = "empty_object", skip_serializing_if = "is_empty_object")]
    pub metadata: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

fn empty_object() -> serde_json::Value {
    serde_json::json!({})
}

fn is_empty_object(v: &serde_json::Value) -> bool {
    v.as_object().is_some_and(|o| o.is_empty()) || v.is_null()
}

fn is_hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

impl RecordLine {
    /// The record as the engine sees it.
    pub fn memory(&self) -> Memory {
        Memory {
            id: self.id,
            tenant: self.tenant.clone(),
            subject: self.subject.clone(),
            kind: self.kind,
            status: self.status,
            content: self.content.clone(),
            session_id: self.session_id.clone(),
            turn_ref: self.turn_ref.clone(),
            occurred_at: self.occurred_at,
            valid_from: self.valid_from,
            valid_to: self.valid_to,
            supersedes: self.supersedes,
            labels: self.labels.clone(),
            tags: self.tags.clone(),
            source: self.source.clone(),
            confidence: self.confidence,
            metadata: self.metadata.clone(),
            created_at: self.created_at,
            expires_at: self.expires_at,
            scope: self.scope.clone(),
            provenance: self.provenance.clone(),
        }
    }

    /// The rules of `docs/memory-format.md` beyond the JSON shape.
    pub fn validate(&self) -> anyhow::Result<()> {
        self.check(true)
    }

    /// `named_successor`: a superseded record must name its successor (v2 lines; a v1 file
    /// recovers it only when the successor is in the same file).
    fn check(&self, named_successor: bool) -> anyhow::Result<()> {
        let fail = |m: String| Err(anyhow::anyhow!("record {}: {m}", self.id));
        if self.tenant.trim().is_empty() || self.subject.trim().is_empty() {
            return fail("tenant and subject must not be empty".into());
        }
        if self.content.is_empty() {
            return fail("content must not be empty".into());
        }
        if !is_hex64(&self.content_hash) || self.alt_hash.as_deref().is_some_and(|h| !is_hex64(h)) {
            return fail("content_hash and alt_hash are lowercase sha256 hex".into());
        }
        if !(0.0..=1.0).contains(&self.confidence) {
            return fail(format!("confidence {} is outside 0..1", self.confidence));
        }
        if self.valid_to.is_some_and(|t| t < self.valid_from) {
            return fail("valid_to is before valid_from".into());
        }
        if self.updated_at < self.created_at {
            return fail("updated_at is before created_at".into());
        }
        if named_successor && self.status == MemoryStatus::Superseded && self.superseded_by.is_none() {
            return fail("a superseded record names its successor (superseded_by)".into());
        }
        if self.kind == MemoryKind::Working && self.expires_at.is_none() {
            return fail("working memory has an expires_at".into());
        }
        if !self.metadata.is_object() {
            return fail("metadata is a JSON object".into());
        }
        if let Some(s) = &self.structured {
            if s.record_type.trim().is_empty() || !s.attrs.is_object() {
                return fail("structured needs a record_type and an attrs object".into());
            }
        }
        let mut paths = std::collections::HashSet::new();
        for c in &self.code_refs {
            if c.path.is_empty() || c.blob_hash.is_empty() || !paths.insert(&c.path) {
                return fail("code_refs need a path and blob_hash, each path once".into());
            }
        }
        Ok(())
    }
}

/// Any line after the header.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Line {
    Policy(PolicyLine),
    Record(Box<RecordLine>),
    Link(Link),
}

impl Line {
    /// The canonical text of the line (no trailing newline).
    pub fn to_canonical(&self) -> String {
        serde_json::to_string(self).expect("lines always serialize")
    }
}

/// Parse and validate one v2 line. Unknown types and unknown fields are errors, so nothing a
/// newer writer added is silently dropped.
pub fn parse_line(text: &str) -> anyhow::Result<Line> {
    let mut v: serde_json::Value = serde_json::from_str(text)?;
    let obj = v.as_object_mut().ok_or_else(|| anyhow::anyhow!("a line is a JSON object"))?;
    let ty = obj.remove("type").and_then(|t| t.as_str().map(String::from)).ok_or_else(|| anyhow::anyhow!("a line needs a \"type\""))?;
    let line = match ty.as_str() {
        "policy" => {
            let p: PolicyLine = serde_json::from_value(v)?;
            anyhow::ensure!(!p.version.trim().is_empty() && p.body.is_object(), "a policy needs a version and a body object");
            Line::Policy(p)
        }
        "record" => {
            let r: RecordLine = serde_json::from_value(v)?;
            r.validate()?;
            Line::Record(Box::new(r))
        }
        "link" => {
            let l: Link = serde_json::from_value(v)?;
            anyhow::ensure!(
                [&l.tenant, &l.subject, &l.linked_subject, &l.link_type].iter().all(|s| !s.trim().is_empty()),
                "a link needs tenant, subject, linked_subject and link_type"
            );
            anyhow::ensure!(l.subject != l.linked_subject, "a link joins two different subjects");
            Line::Link(l)
        }
        other => anyhow::bail!("unknown line type '{other}'"),
    };
    Ok(line)
}

/// Parse a header line of either version. Returns the version and, for v2, the header.
pub fn parse_header(text: &str) -> anyhow::Result<(u32, Option<Header>)> {
    let v: serde_json::Value = serde_json::from_str(text).map_err(|e| anyhow::anyhow!("not a MemHouse export (header: {e})"))?;
    anyhow::ensure!(v["format"] == FORMAT, "not a MemHouse export (the first line's format is not \"{FORMAT}\")");
    match v["version"].as_u64() {
        Some(1) => Ok((1, None)),
        Some(2) => {
            let h: Header = serde_json::from_value(v)?;
            anyhow::ensure!(h.schema_version <= SCHEMA_VERSION, "written for schema {}, this build reads up to {SCHEMA_VERSION}", h.schema_version);
            Ok((2, Some(h)))
        }
        Some(n) => anyhow::bail!("format version {n} is newer than this build reads ({VERSION}); upgrade MemHouse"),
        None => anyhow::bail!("the header has no version"),
    }
}

/// The deduplication key the engine gives a record (same scheme as `remember`, `ingest` and
/// enrichment), for v1 files that didn't carry it.
pub fn record_hash(m: &Memory) -> String {
    let session = m.session_id.clone().unwrap_or_default();
    if m.metadata["derived"] == true {
        content_hash(&format!("fact\u{1f}{session}\u{1f}{}", m.content))
    } else if m.kind == MemoryKind::Episodic && m.metadata.get("round").is_some() {
        content_hash(&format!("episodic\u{1f}{session}\u{1f}{}\u{1f}{}", m.metadata["round"], m.content))
    } else {
        content_hash(&format!("{}\u{1f}{}", m.kind.as_str(), m.content))
    }
}

/// Provenance of a record written before schema v2, from what it did record. The Postgres
/// backfill applies the same rules (`docs/schema.md`, "Upgrading from v1").
pub fn legacy_provenance(m: &Memory) -> Provenance {
    let derived = m.metadata["derived"] == true;
    Provenance {
        agent: Some(if m.source.starts_with("enrich:") { "enrich".into() } else { m.source.clone() }),
        user: None,
        policy_version: Some(LEGACY_POLICY.into()),
        request_key: None,
        extractor: m.metadata["extractor"].as_str().filter(|_| derived).map(String::from),
        extractor_config: m.metadata["prompt_version"].as_str().filter(|_| derived).map(String::from),
    }
}

/// The records of a v1 file as v2 records: provenance from what v1 recorded, `superseded_by`
/// from the records in the file that name a predecessor.
pub fn upgrade_v1(memories: Vec<Memory>) -> anyhow::Result<Vec<RecordLine>> {
    let mut all: Vec<RecordLine> = memories.into_iter().map(from_v1).collect();
    let successor: std::collections::HashMap<Uuid, Uuid> = all.iter().filter_map(|r| r.supersedes.map(|old| (old, r.id))).collect();
    for r in all.iter_mut() {
        if r.status == MemoryStatus::Superseded {
            r.superseded_by = successor.get(&r.id).copied();
        }
        r.check(false)?;
    }
    Ok(all)
}

/// A v1 line (a serialized `Memory` of that time) as a v2 record, before `upgrade_v1` links
/// the versions.
fn from_v1(m: Memory) -> RecordLine {
    let provenance = legacy_provenance(&m);
    RecordLine {
        id: m.id,
        content_hash: record_hash(&m),
        tenant: m.tenant,
        subject: m.subject,
        kind: m.kind,
        status: m.status,
        content: m.content,
        session_id: m.session_id,
        turn_ref: m.turn_ref,
        occurred_at: m.occurred_at,
        valid_from: m.valid_from,
        valid_to: m.valid_to,
        expires_at: m.expires_at,
        supersedes: m.supersedes,
        superseded_by: None,
        labels: m.labels,
        tags: m.tags,
        scope: m.scope,
        source: m.source,
        confidence: m.confidence,
        provenance,
        alt_hash: None,
        structured: None,
        code_refs: vec![],
        metadata: if m.metadata.is_null() { empty_object() } else { m.metadata },
        created_at: m.created_at,
        updated_at: m.created_at,
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ExportReport {
    pub policies: u64,
    pub records: u64,
    pub links: u64,
}

/// Write a tenant (or one subject) in Memory Format v2.
pub async fn export(engine: &Engine, w: &mut dyn Write, tenant: &str, subject: Option<&str>) -> anyhow::Result<ExportReport> {
    let (embedder, _) = engine.store.embedding_identity().await.unwrap_or((None, None));
    let header = Header {
        format: FORMAT.into(),
        version: VERSION,
        schema_version: SCHEMA_VERSION,
        producer: format!("memhouse {}", env!("CARGO_PKG_VERSION")),
        exported_at: Utc::now(),
        tenant: tenant.into(),
        subject: subject.map(String::from),
        embedder,
    };
    writeln!(w, "{}", serde_json::to_string(&header)?)?;
    let mut rep = ExportReport::default();
    for p in engine.store.export_policies().await? {
        writeln!(w, "{}", Line::Policy(p).to_canonical())?;
        rep.policies += 1;
    }
    let mut after = None;
    loop {
        let page = engine.store.export_records(tenant, subject, after, 1000).await?;
        let Some(last) = page.last() else { break };
        after = Some(last.id);
        for r in page {
            writeln!(w, "{}", Line::Record(Box::new(r)).to_canonical())?;
            rep.records += 1;
        }
    }
    for l in engine.store.export_links(tenant, subject).await? {
        writeln!(w, "{}", Line::Link(l).to_canonical())?;
        rep.links += 1;
    }
    Ok(rep)
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ImportReport {
    pub version: u32,
    pub policies: u64,
    pub records: u64,
    /// Records whose id was already present (left as they are).
    pub skipped: u64,
    pub links: u64,
    /// Rounds whose second vector couldn't be rebuilt (their user-only text wasn't recoverable).
    pub second_vectors_dropped: u64,
}

/// Read a v1 or v2 file. Records keep their ids, timestamps, states and provenance; vectors are
/// made with the engine's embedder. Records already present are skipped, so an import can be
/// repeated.
pub async fn import(engine: &Engine, r: impl BufRead, actor: &str) -> anyhow::Result<ImportReport> {
    let mut lines = r.lines().enumerate();
    let (_, first) = lines.next().ok_or_else(|| anyhow::anyhow!("empty file"))?;
    let (version, _) = parse_header(&first?)?;
    let mut rep = ImportReport { version, ..Default::default() };
    let mut pending: Vec<RecordLine> = vec![];
    let mut links: Vec<Link> = vec![];
    if version == 1 {
        let mut memories = vec![];
        for (n, l) in lines {
            let l = l?;
            if l.trim().is_empty() {
                continue;
            }
            memories.push(serde_json::from_str::<Memory>(&l).map_err(|e| anyhow::anyhow!("line {}: {e}", n + 1))?);
        }
        let all = upgrade_v1(memories)?;
        for chunk in all.chunks(256) {
            insert_records(engine, chunk, &mut rep).await?;
        }
    } else {
        for (n, l) in lines {
            let l = l?;
            if l.trim().is_empty() {
                continue;
            }
            match parse_line(&l).map_err(|e| anyhow::anyhow!("line {}: {e:#}", n + 1))? {
                Line::Policy(p) => {
                    engine.store.policy_put(&p).await?;
                    rep.policies += 1;
                }
                Line::Record(r) => {
                    pending.push(*r);
                    if pending.len() == 256 {
                        insert_records(engine, &pending, &mut rep).await?;
                        pending.clear();
                    }
                }
                Line::Link(l) => links.push(l),
            }
        }
        insert_records(engine, &pending, &mut rep).await?;
        for l in &links {
            engine.store.link_put(l).await?;
            rep.links += 1;
        }
    }
    engine.store.audit(actor, "memory.import", &engine.cfg.memory.tenant, None, None, serde_json::to_value(&rep)?).await?;
    Ok(rep)
}

async fn insert_records(engine: &Engine, recs: &[RecordLine], rep: &mut ImportReport) -> anyhow::Result<()> {
    if recs.is_empty() {
        return Ok(());
    }
    let prefix = engine.cfg.embedding.passage_prefix.clone().unwrap_or_default();
    let mut texts: Vec<String> = recs.iter().map(|r| r.content.clone()).collect();
    let n = texts.len();
    let mut alts = vec![];
    for (i, r) in recs.iter().enumerate() {
        let Some(h) = &r.alt_hash else { continue };
        match recover_focus(&r.content, h, &[prefix.as_str(), ""]) {
            Some(f) => {
                alts.push((i, content_hash(&format!("{prefix}{f}"))));
                texts.push(f);
            }
            None => rep.second_vectors_dropped += 1,
        }
    }
    let mut vecs = engine.embed_passages(&texts).await?;
    let alt_vecs = vecs.split_off(n);
    let mut rows: Vec<ImportRow> = recs
        .iter()
        .cloned()
        .zip(vecs)
        .map(|(mut record, v)| {
            record.alt_hash = None;
            ImportRow { record, embedding: Some(v), alt: None }
        })
        .collect();
    for ((i, h), v) in alts.into_iter().zip(alt_vecs) {
        rows[i].record.alt_hash = Some(h.clone());
        rows[i].alt = Some((h, v));
    }
    let added = engine.store.import_records(&rows).await?;
    rep.records += added;
    rep.skipped += recs.len() as u64 - added;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../memory-format/vectors")
    }

    /// Every conformance vector behaves as its manifest says: valid files parse, and v2 lines are
    /// already canonical (re-serializing reproduces them byte for byte); invalid files fail with
    /// the stated message.
    #[test]
    fn conformance_vectors() {
        let manifest: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(vectors_dir().join("manifest.json")).unwrap()).unwrap();
        let cases = manifest["cases"].as_array().unwrap();
        assert!(cases.len() >= 10, "manifest lists {} cases", cases.len());
        for case in cases {
            let file = case["file"].as_str().unwrap();
            let text = std::fs::read_to_string(vectors_dir().join(file)).unwrap();
            let outcome = check_file(&text);
            match case["error"].as_str() {
                None => {
                    let (records, links, policies) = outcome.unwrap_or_else(|e| panic!("{file} should be valid: {e:#}"));
                    assert_eq!(records, case["records"].as_u64().unwrap(), "{file} records");
                    assert_eq!(links, case["links"].as_u64().unwrap_or(0), "{file} links");
                    assert_eq!(policies, case["policies"].as_u64().unwrap_or(0), "{file} policies");
                }
                Some(want) => {
                    let err = format!("{:#}", outcome.err().unwrap_or_else(|| panic!("{file} should be rejected")));
                    assert!(err.contains(want), "{file}: expected an error containing {want:?}, got {err:?}");
                }
            }
        }
    }

    /// Parse a whole file the way `import` does, without a store. Returns (records, links, policies).
    fn check_file(text: &str) -> anyhow::Result<(u64, u64, u64)> {
        let mut lines = text.lines();
        let (version, _) = parse_header(lines.next().unwrap_or_default())?;
        let (mut r, mut l, mut p) = (0, 0, 0);
        let lines: Vec<&str> = lines.filter(|l| !l.trim().is_empty()).collect();
        if version == 1 {
            let memories = lines.iter().map(|l| serde_json::from_str::<Memory>(l)).collect::<Result<Vec<_>, _>>()?;
            return Ok((upgrade_v1(memories)?.len() as u64, 0, 0));
        }
        for line in lines {
            let parsed = parse_line(line)?;
            assert_eq!(parsed.to_canonical(), line, "vector lines are canonical");
            match parsed {
                Line::Policy(_) => p += 1,
                Line::Record(_) => r += 1,
                Line::Link(_) => l += 1,
            }
        }
        Ok((r, l, p))
    }

    #[test]
    fn lifecycle_transitions() {
        use MemoryStatus::*;
        assert!(Candidate.can_become(Committed) && Quarantined.can_become(Committed) && Committed.can_become(Superseded));
        for t in [Superseded, Rejected, Expired] {
            assert!(t.is_terminal());
            assert!(MemoryStatus::ALL.iter().all(|to| !t.can_become(*to)), "{t:?} is terminal");
        }
        assert!(!Committed.can_become(Candidate) && !Superseded.can_become(Committed));
        assert_eq!(MemoryStatus::sources_of(Committed), vec![Candidate, Quarantined]);
    }
}
