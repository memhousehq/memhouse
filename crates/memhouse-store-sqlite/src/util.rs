// SPDX-License-Identifier: Apache-2.0
//! Conversions between the engine's types and SQLite's (see `schema`), and small query helpers.

use chrono::{DateTime, Utc};
use memhouse_core::types::*;
use rusqlite::{Connection, Params, Row};
use uuid::Uuid;

/// Timestamps are stored as microseconds since the epoch: they compare as integers.
pub(crate) fn us(t: DateTime<Utc>) -> i64 {
    t.timestamp_micros()
}

pub(crate) fn at(us: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_micros(us).unwrap_or(DateTime::UNIX_EPOCH)
}

pub(crate) fn now() -> i64 {
    us(Utc::now())
}

pub(crate) fn json<T: serde::Serialize + ?Sized>(v: &T) -> anyhow::Result<String> {
    Ok(serde_json::to_string(v)?)
}

/// A list of ids as the JSON array of strings the statements read with `json_each`.
pub(crate) fn ids_json(ids: &[Uuid]) -> String {
    serde_json::Value::from(ids.iter().map(|u| u.to_string()).collect::<Vec<_>>()).to_string()
}

pub(crate) fn uuid_of(s: &str) -> anyhow::Result<Uuid> {
    Uuid::parse_str(s).map_err(|e| anyhow::anyhow!("unreadable id {s:?} in the database: {e}"))
}

pub(crate) fn uuids(json: &str) -> anyhow::Result<Vec<Uuid>> {
    serde_json::from_str::<Vec<String>>(json)?.iter().map(|s| uuid_of(s)).collect()
}

pub(crate) fn strings(json: &str) -> anyhow::Result<Vec<String>> {
    Ok(serde_json::from_str(json)?)
}

pub(crate) fn value(json: &str) -> anyhow::Result<serde_json::Value> {
    Ok(serde_json::from_str(json)?)
}

pub(crate) fn opt_at(r: &Row, col: &str) -> anyhow::Result<Option<DateTime<Utc>>> {
    Ok(r.get::<_, Option<i64>>(col)?.map(at))
}

pub(crate) fn opt_uuid(r: &Row, col: &str) -> anyhow::Result<Option<Uuid>> {
    r.get::<_, Option<String>>(col)?.map(|s| uuid_of(&s)).transpose()
}

/// Every row of a statement, mapped.
pub(crate) fn rows<T>(c: &Connection, sql: &str, params: impl Params, mut map: impl FnMut(&Row) -> anyhow::Result<T>) -> anyhow::Result<Vec<T>> {
    let mut st = c.prepare_cached(sql)?;
    let mut rows = st.query(params)?;
    let mut out = vec![];
    while let Some(r) = rows.next()? {
        out.push(map(r)?);
    }
    Ok(out)
}

/// The first row of a statement, mapped.
pub(crate) fn first<T>(c: &Connection, sql: &str, params: impl Params, map: impl FnOnce(&Row) -> anyhow::Result<T>) -> anyhow::Result<Option<T>> {
    let mut st = c.prepare_cached(sql)?;
    let mut rows = st.query(params)?;
    match rows.next()? {
        Some(r) => Ok(Some(map(r)?)),
        None => Ok(None),
    }
}

/// Run a statement; the number of rows it changed.
pub(crate) fn exec(c: &Connection, sql: &str, params: impl Params) -> anyhow::Result<u64> {
    Ok(c.prepare_cached(sql)?.execute(params)? as u64)
}

pub(crate) const COLS: &str = "m.id, m.tenant, m.subject, m.kind, m.status, m.content, m.session_id, m.turn_ref, \
    m.occurred_at, m.valid_from, m.valid_to, m.supersedes, m.labels, m.tags, m.source, m.confidence, \
    m.metadata, m.created_at, m.expires_at, m.scope_org, m.scope_team, m.scope_agent, m.scope_user, m.scope_session, \
    m.prov_agent, m.prov_user, m.policy_version, m.request_key, m.extractor, m.extractor_config, m.language";

pub(crate) fn memory_of(r: &Row) -> anyhow::Result<Memory> {
    let kind: String = r.get("kind")?;
    let status: String = r.get("status")?;
    Ok(Memory {
        id: uuid_of(&r.get::<_, String>("id")?)?,
        tenant: r.get("tenant")?,
        subject: r.get("subject")?,
        kind: MemoryKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown kind '{kind}' in the database"))?,
        status: MemoryStatus::parse(&status).ok_or_else(|| anyhow::anyhow!("unknown status '{status}' in the database"))?,
        content: r.get("content")?,
        session_id: r.get("session_id")?,
        turn_ref: r.get("turn_ref")?,
        occurred_at: opt_at(r, "occurred_at")?,
        valid_from: at(r.get("valid_from")?),
        valid_to: opt_at(r, "valid_to")?,
        supersedes: opt_uuid(r, "supersedes")?,
        labels: strings(&r.get::<_, String>("labels")?)?,
        tags: strings(&r.get::<_, String>("tags")?)?,
        source: r.get("source")?,
        confidence: r.get::<_, f64>("confidence")? as f32,
        metadata: value(&r.get::<_, String>("metadata")?)?,
        created_at: at(r.get("created_at")?),
        expires_at: opt_at(r, "expires_at")?,
        scope: Scope { org: r.get("scope_org")?, team: r.get("scope_team")?, agent: r.get("scope_agent")?, user: r.get("scope_user")?, session: r.get("scope_session")? },
        provenance: Provenance {
            agent: r.get("prov_agent")?,
            user: r.get("prov_user")?,
            policy_version: r.get("policy_version")?,
            request_key: r.get("request_key")?,
            extractor: r.get("extractor")?,
            extractor_config: r.get("extractor_config")?,
        },
        language: r.get("language")?,
    })
}

/// Postgres' `@>` on JSON documents: `a` contains `b` when every key of an object in `b` is in
/// `a` with a contained value, every element of an array in `b` is contained in some element
/// of `a`'s, and scalars are equal.
pub(crate) fn json_contains(a: &serde_json::Value, b: &serde_json::Value) -> bool {
    use serde_json::Value::*;
    match (a, b) {
        (Object(x), Object(y)) => y.iter().all(|(k, v)| x.get(k).is_some_and(|w| json_contains(w, v))),
        (Array(x), Array(y)) => y.iter().all(|v| x.iter().any(|w| json_contains(w, v))),
        // An array contains a scalar that is one of its elements (top level only in Postgres;
        // attributes are objects, so the difference is never reached).
        (Array(_), _) | (Object(_), _) | (_, Array(_)) | (_, Object(_)) => false,
        // Numbers by value, as `jsonb` compares them: 1 equals 1.0. Two integers are compared
        // exactly, so integers beyond a float's precision stay distinct.
        (Number(x), Number(y)) => match (x.as_i64().map(i128::from).or(x.as_u64().map(i128::from)), y.as_i64().map(i128::from).or(y.as_u64().map(i128::from))) {
            (Some(i), Some(j)) => i == j,
            _ => x.as_f64() == y.as_f64(),
        },
        _ => a == b,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn containment_matches_postgres() {
        let a = json!({ "city": "Porto", "tags": ["a", "b"], "geo": { "lat": 41, "lon": -8 } });
        assert!(json_contains(&a, &json!({})));
        assert!(json_contains(&a, &json!({ "city": "Porto" })));
        assert!(json_contains(&a, &json!({ "tags": ["b"], "geo": { "lat": 41 } })));
        assert!(!json_contains(&a, &json!({ "city": "porto" })));
        assert!(!json_contains(&a, &json!({ "tags": ["c"] })));
        assert!(!json_contains(&a, &json!({ "missing": null })));
        // Numbers by value: an integer and the same number written as a float are equal.
        assert!(json_contains(&a, &json!({ "geo": { "lat": 41.0 } })) && json_contains(&json!({ "n": 2.0 }), &json!({ "n": 2 })));
        assert!(!json_contains(&a, &json!({ "geo": { "lat": 41.5 } })) && !json_contains(&a, &json!({ "geo": { "lat": "41" } })));
        assert!(!json_contains(&json!({ "n": 9007199254740993u64 }), &json!({ "n": 9007199254740992u64 })));
    }

    #[test]
    fn timestamps_keep_microseconds() {
        let t = DateTime::parse_from_rfc3339("2026-11-20T10:11:12.123456Z").unwrap().with_timezone(&Utc);
        assert_eq!(at(us(t)), t);
    }
}
