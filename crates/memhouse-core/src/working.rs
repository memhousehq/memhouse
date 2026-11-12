// SPDX-License-Identifier: Apache-2.0
//! Session working memory (MEM-01, PERF-05): the scratchpad of one session, served from an
//! in-process cache so a recall inside the session sees it first without a database round trip.
//!
//! The cache holds nothing the store doesn't (DEP-08: the service stays stateless): an entry is
//! the session's committed working records, loaded from the store on first use, updated by the
//! writes this process makes, dropped by anything that could change them (a deletion, a revision,
//! a relabel, retention), and read again after `memory.working_cache_secs`, so a change made
//! through another process shows within that time. Access rules are applied to what the cache
//! returns on every read: the cache is per session, not per reader.

use crate::types::Memory;
use chrono::{DateTime, Utc};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;

/// (tenant, subject, session).
type Key = (String, String, String);

struct Entry {
    /// Newest first.
    items: Vec<Memory>,
    loaded: Instant,
    used: Instant,
}

pub struct WorkingCache {
    entries: Mutex<HashMap<Key, Entry>>,
    /// Counts invalidations. What a task read from the store before an invalidation (a load, a
    /// record it just committed) may be older than the deletion or relabel that caused it, so it
    /// is not put into the cache afterwards: the task passes the generation it started under.
    generation: AtomicU64,
    ttl: Duration,
    max_sessions: usize,
    max_items: usize,
}

impl WorkingCache {
    pub fn new(ttl_secs: u64, max_sessions: usize, max_items: usize) -> WorkingCache {
        WorkingCache {
            entries: Mutex::new(HashMap::new()),
            generation: AtomicU64::new(0),
            ttl: Duration::from_secs(ttl_secs),
            max_sessions: max_sessions.max(1),
            max_items: max_items.max(1),
        }
    }

    pub fn enabled(&self) -> bool {
        !self.ttl.is_zero()
    }

    /// Records per session the cache keeps (and a load asks the store for).
    pub fn max_items(&self) -> usize {
        self.max_items
    }

    /// The current generation: read it before reading the store, pass it to `put` or `wrote`.
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    fn invalidated(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    fn key(tenant: &str, subject: &str, session: &str) -> Key {
        (tenant.to_string(), subject.to_string(), session.to_string())
    }

    /// The session's live working memory, newest first, if the cache holds it and it is fresh.
    pub fn get(&self, tenant: &str, subject: &str, session: &str, now: DateTime<Utc>) -> Option<Vec<Memory>> {
        if !self.enabled() {
            return None;
        }
        let mut m = self.entries.lock().ok()?;
        let e = m.get_mut(&Self::key(tenant, subject, session)).filter(|e| e.loaded.elapsed() < self.ttl)?;
        e.used = Instant::now();
        Some(e.items.iter().filter(|i| i.expires_at.is_none_or(|t| t > now)).cloned().collect())
    }

    /// Keep what the store returned for a session (newest first), unless something was
    /// invalidated since `generation` was read (the load may predate a deletion).
    pub fn put(&self, generation: u64, tenant: &str, subject: &str, session: &str, mut items: Vec<Memory>) {
        if !self.enabled() {
            return;
        }
        items.truncate(self.max_items);
        let Ok(mut m) = self.entries.lock() else { return };
        // Checked under the lock the invalidations take, so none can slip in between.
        if self.generation() != generation {
            return;
        }
        if m.len() >= self.max_sessions && !m.contains_key(&Self::key(tenant, subject, session)) {
            // Evict the least recently used session.
            if let Some(oldest) = m.iter().min_by_key(|(_, e)| e.used).map(|(k, _)| k.clone()) {
                m.remove(&oldest);
            }
        }
        let now = Instant::now();
        m.insert(Self::key(tenant, subject, session), Entry { items, loaded: now, used: now });
    }

    /// A record this process just committed to the session: added in front if the session is
    /// cached (an uncached session loads it from the store on its next read). The session's other
    /// records take the new expiry, as they did in the store (`ttl` marks those that follow it).
    /// If something was invalidated since `generation` was read, the copy in hand may be stale (a
    /// relabel, a deletion): the session is dropped instead and reads the store next time.
    pub fn wrote(&self, generation: u64, record: &Memory, session: &str, extended_to: Option<DateTime<Utc>>) {
        let Ok(mut m) = self.entries.lock() else { return };
        let key = Self::key(&record.tenant, &record.subject, session);
        if self.generation() != generation {
            m.remove(&key);
            return;
        }
        let Some(e) = m.get_mut(&key) else { return };
        e.items.retain(|i| i.id != record.id);
        if let Some(t) = extended_to {
            for i in e.items.iter_mut().filter(|i| i.metadata.get("ttl").and_then(|v| v.as_str()) == Some("session")) {
                i.expires_at = i.expires_at.map(|old| old.max(t));
            }
        }
        e.items.insert(0, record.clone());
        e.items.truncate(self.max_items);
    }

    /// Forget one session (its next read loads it again).
    pub fn drop_session(&self, tenant: &str, subject: &str, session: &str) {
        if let Ok(mut m) = self.entries.lock() {
            self.invalidated();
            m.remove(&Self::key(tenant, subject, session));
        }
    }

    /// Forget every session that holds the record.
    pub fn drop_record(&self, id: Uuid) {
        if let Ok(mut m) = self.entries.lock() {
            self.invalidated();
            m.retain(|_, e| !e.items.iter().any(|i| i.id == id));
        }
    }

    /// Forget every session of a subject (erasure).
    pub fn drop_subject(&self, tenant: &str, subject: &str) {
        if let Ok(mut m) = self.entries.lock() {
            self.invalidated();
            m.retain(|k, _| !(k.0 == tenant && k.1 == subject));
        }
    }

    /// Forget everything (erasure by user, agent, source or tenant; retention).
    pub fn clear(&self) {
        if let Ok(mut m) = self.entries.lock() {
            self.invalidated();
            m.clear();
        }
    }

    pub fn sessions(&self) -> usize {
        self.entries.lock().map(|m| m.len()).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::*;

    fn rec(session: &str, text: &str, ttl_secs: i64) -> Memory {
        let now = Utc::now();
        Memory {
            id: Uuid::now_v7(),
            tenant: "t".into(),
            subject: "s".into(),
            kind: MemoryKind::Working,
            status: MemoryStatus::Committed,
            content: text.into(),
            session_id: None,
            turn_ref: None,
            occurred_at: None,
            valid_from: now,
            valid_to: None,
            supersedes: None,
            labels: vec![],
            tags: vec![],
            source: "t".into(),
            confidence: 1.0,
            metadata: serde_json::json!({ "ttl": "session" }),
            created_at: now,
            expires_at: Some(now + chrono::Duration::seconds(ttl_secs)),
            scope: Scope { session: Some(session.into()), ..Default::default() },
            provenance: Provenance::default(),
        }
    }

    /// PERF-05: a hit returns the session's live records, newest first; expiry and the entry's
    /// own lifetime are honoured.
    #[test]
    fn serves_live_records_until_stale() {
        let c = WorkingCache::new(60, 10, 3);
        assert!(c.get("t", "s", "a", Utc::now()).is_none());
        c.put(c.generation(), "t", "s", "a", vec![rec("a", "two", 60), rec("a", "one", -1)]);
        let got = c.get("t", "s", "a", Utc::now()).unwrap();
        assert_eq!(got.iter().map(|m| m.content.as_str()).collect::<Vec<_>>(), vec!["two"]);
        // A write goes in front, extends the session's records, and the entry stays bounded.
        let later = Utc::now() + chrono::Duration::seconds(600);
        for t in ["three", "four", "five"] {
            c.wrote(c.generation(), &rec("a", t, 600), "a", Some(later));
        }
        let got = c.get("t", "s", "a", Utc::now()).unwrap();
        assert_eq!(got.iter().map(|m| m.content.as_str()).collect::<Vec<_>>(), vec!["five", "four", "three"]);
        // Another session is another entry; a write to an uncached session caches nothing.
        c.wrote(c.generation(), &rec("b", "other", 60), "b", None);
        assert!(c.get("t", "s", "b", Utc::now()).is_none());
        let stale = WorkingCache::new(0, 10, 3);
        stale.put(stale.generation(), "t", "s", "a", vec![rec("a", "x", 60)]);
        assert!(stale.get("t", "s", "a", Utc::now()).is_none());
    }

    #[test]
    fn evicts_and_drops() {
        let c = WorkingCache::new(60, 2, 5);
        c.put(c.generation(), "t", "s", "a", vec![rec("a", "a", 60)]);
        std::thread::sleep(Duration::from_millis(2));
        c.put(c.generation(), "t", "s", "b", vec![rec("b", "b", 60)]);
        std::thread::sleep(Duration::from_millis(2));
        // Using `a` makes `b` the least recently used.
        c.get("t", "s", "a", Utc::now());
        c.put(c.generation(), "t", "s", "c", vec![rec("c", "c", 60)]);
        assert_eq!(c.sessions(), 2);
        assert!(c.get("t", "s", "b", Utc::now()).is_none() && c.get("t", "s", "a", Utc::now()).is_some());
        let r = rec("a", "gone", 60);
        c.put(c.generation(), "t", "s", "a", vec![r.clone()]);
        c.drop_record(r.id);
        assert!(c.get("t", "s", "a", Utc::now()).is_none());
        // A load or a write that started before an invalidation can't bring the record back.
        let before = c.generation();
        c.drop_record(r.id);
        c.put(before, "t", "s", "a", vec![r.clone()]);
        assert!(c.get("t", "s", "a", Utc::now()).is_none());
        c.put(c.generation(), "t", "s", "a", vec![]);
        let before = c.generation();
        c.drop_record(Uuid::now_v7());
        c.wrote(before, &r, "a", None);
        assert!(c.get("t", "s", "a", Utc::now()).is_none());
        c.drop_subject("t", "s");
        assert_eq!(c.sessions(), 0);
    }
}
