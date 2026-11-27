// SPDX-License-Identifier: Apache-2.0
//! SIEM export (GOV-15): every audit event, in order, to a syslog receiver as CEF and to an
//! OpenTelemetry collector as OTLP logs, within seconds of being written.
//!
//! The exporter reads the audit log after a cursor it keeps in the store, sends a batch, and
//! advances the cursor only once the sink has taken it: an event is delivered at least once,
//! and a sink that is down delays its events without losing them. With several replicas one
//! holds a lease and exports; the others stand by. Events hold identifiers, counts and hashes,
//! never memory content (PR-3), so nothing else reaches the SIEM.

use chrono::Utc;
use memhouse_core::config::SiemConfig;
use memhouse_core::types::AuditEvent;
use memhouse_core::{Engine, Store};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

/// Seconds a replica's lease on the export lasts without being renewed.
const LEASE_SECS: i64 = 60;

/// How urgent an event is, as a CEF severity (0 to 10).
fn severity(action: &str) -> u8 {
    match action {
        "auth.failed" | "access.denied" => 6,
        a if a.ends_with(".erase") || a.ends_with(".delete") || a == "memory.forget" || a.starts_with("hold.") || a.starts_with("deletion.") || a == "backup.restore" => 5,
        a if a.starts_with("policy.") || a.starts_with("key.") || a.starts_with("principal.") => 4,
        _ => 3,
    }
}

/// A CEF header field: `|` and `\` escaped, no line breaks.
fn cef_header(s: &str) -> String {
    s.replace('\\', "\\\\").replace('|', "\\|").replace(['\r', '\n'], " ")
}

/// A CEF extension value: `\`, `=` and line breaks escaped.
fn cef_value(s: &str) -> String {
    s.replace('\\', "\\\\").replace('=', "\\=").replace('\r', "\\r").replace('\n', "\\n")
}

/// One audit event as a CEF message (ArcSight Common Event Format, version 0).
pub fn cef(e: &AuditEvent) -> String {
    let mut ext = format!(
        "rt={} externalId={} suser={} cs1Label=tenant cs1={} cs5Label=hash cs5={} cs6Label=prevHash cs6={}",
        e.at.timestamp_millis(),
        e.id,
        cef_value(&e.actor),
        cef_value(&e.tenant),
        cef_value(&e.hash),
        cef_value(&e.prev_hash),
    );
    if let Some(s) = &e.subject {
        ext.push_str(&format!(" cs2Label=subject cs2={}", cef_value(s)));
    }
    if let Some(m) = e.memory_id {
        ext.push_str(&format!(" cs3Label=memoryId cs3={m}"));
    }
    ext.push_str(&format!(" cs4Label=detail cs4={}", cef_value(&e.detail.to_string())));
    format!("CEF:0|MemHouse|memhouse|{}|{}|{}|{}|{ext}", env!("CARGO_PKG_VERSION"), cef_header(&e.action), cef_header(&e.action), severity(&e.action))
}

/// The CEF message framed as RFC 5424 syslog: facility 13 (log audit), severity 6 (informational).
pub fn syslog_line(e: &AuditEvent, host: &str) -> String {
    format!(
        "<110>1 {} {} memhouse {} {} - {}",
        e.at.to_rfc3339_opts(chrono::SecondsFormat::Micros, true),
        host,
        std::process::id(),
        cef_header(&e.action).replace(' ', "_"),
        cef(e)
    )
}

/// A batch of audit events as the body of an OTLP/HTTP logs request (JSON encoding).
pub fn otlp_body(events: &[AuditEvent], service: &str) -> serde_json::Value {
    let s = |v: &str| json!({ "stringValue": v });
    let records: Vec<serde_json::Value> = events
        .iter()
        .map(|e| {
            let nanos = e.at.timestamp_nanos_opt().unwrap_or(0).to_string();
            let mut attrs = vec![
                json!({ "key": "event.name", "value": s("memhouse.audit") }),
                json!({ "key": "memhouse.audit.id", "value": { "intValue": e.id.to_string() } }),
                json!({ "key": "memhouse.audit.action", "value": s(&e.action) }),
                json!({ "key": "memhouse.audit.actor", "value": s(&e.actor) }),
                json!({ "key": "memhouse.tenant", "value": s(&e.tenant) }),
                json!({ "key": "memhouse.audit.hash", "value": s(&e.hash) }),
                json!({ "key": "memhouse.audit.prev_hash", "value": s(&e.prev_hash) }),
                json!({ "key": "memhouse.audit.detail", "value": s(&e.detail.to_string()) }),
            ];
            if let Some(subject) = &e.subject {
                attrs.push(json!({ "key": "memhouse.subject", "value": s(subject) }));
            }
            if let Some(m) = e.memory_id {
                attrs.push(json!({ "key": "memhouse.memory_id", "value": s(&m.to_string()) }));
            }
            // INFO is 9, WARN 13: a refused credential or operation is a warning.
            let warn = severity(&e.action) >= 6;
            json!({
                "timeUnixNano": nanos, "observedTimeUnixNano": Utc::now().timestamp_nanos_opt().unwrap_or(0).to_string(),
                "severityNumber": if warn { 13 } else { 9 }, "severityText": if warn { "WARN" } else { "INFO" },
                "body": s(&e.action), "attributes": attrs,
            })
        })
        .collect();
    json!({ "resourceLogs": [{
        "resource": { "attributes": [{ "key": "service.name", "value": s(service) }, { "key": "service.version", "value": s(env!("CARGO_PKG_VERSION")) }] },
        "scopeLogs": [{ "scope": { "name": "memhouse.audit" }, "logRecords": records }],
    }] })
}

fn host_port(url: &str) -> anyhow::Result<&str> {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url).trim_end_matches('/');
    anyhow::ensure!(rest.contains(':'), "siem.syslog needs a port: {url}");
    Ok(rest)
}

/// Send a batch to the syslog receiver: one message per line over TCP, one datagram each over UDP.
async fn send_syslog(target: &str, events: &[AuditEvent], host: &str) -> anyhow::Result<()> {
    let addr = host_port(target)?;
    if target.starts_with("udp://") {
        let socket = tokio::net::UdpSocket::bind("0.0.0.0:0").await?;
        socket.connect(addr).await?;
        for e in events {
            socket.send(syslog_line(e, host).as_bytes()).await?;
        }
        return Ok(());
    }
    let mut stream = tokio::time::timeout(Duration::from_secs(10), tokio::net::TcpStream::connect(addr)).await.map_err(|_| anyhow::anyhow!("connecting to {addr} timed out"))??;
    let mut out = String::new();
    for e in events {
        // A line break inside a message would split it: the CEF text has none (they are escaped).
        out.push_str(&syslog_line(e, host));
        out.push('\n');
    }
    stream.write_all(out.as_bytes()).await?;
    stream.flush().await?;
    stream.shutdown().await?;
    Ok(())
}

async fn send_otlp(http: &reqwest::Client, cfg: &SiemConfig, events: &[AuditEvent], service: &str) -> anyhow::Result<()> {
    let url = format!("{}/v1/logs", cfg.otlp_endpoint.trim().trim_end_matches('/'));
    let mut req = http.post(&url).timeout(Duration::from_secs(15)).json(&otlp_body(events, service));
    for (name, var) in &cfg.otlp_headers_env {
        // The value is read from the environment for this request and goes nowhere else.
        let value = std::env::var(var).map_err(|_| anyhow::anyhow!("siem.otlp_headers_env: the environment variable {var} (header {name}) is not set"))?;
        req = req.header(name, value);
    }
    let resp = req.send().await.map_err(|e| anyhow::anyhow!("OTLP export to {url}: {}", e.without_url()))?;
    anyhow::ensure!(resp.status().is_success(), "OTLP export to {url}: HTTP {}", resp.status());
    Ok(())
}

/// What one pass of the exporter did.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Pass {
    /// Events sent, by sink (`syslog`, `otlp`).
    pub sent: std::collections::BTreeMap<String, u64>,
    /// The longest time between an event being written and being sent, in milliseconds.
    pub max_delay_ms: i64,
    /// False when another replica holds the export.
    pub leader: bool,
    /// The sinks that failed, with why; their events are sent again by the next pass.
    pub errors: Vec<String>,
}

/// The exporter of one process.
pub struct Exporter {
    store: Arc<dyn Store>,
    cfg: SiemConfig,
    service: String,
    http: reqwest::Client,
    /// Who holds the lease when this process does.
    holder: String,
    host: String,
}

impl Exporter {
    pub fn new(engine: &Engine) -> Exporter {
        Exporter::with(engine.store.clone(), engine.cfg.siem.clone(), &engine.cfg.telemetry.service_name)
    }

    pub fn with(store: Arc<dyn Store>, cfg: SiemConfig, service: &str) -> Exporter {
        let host = std::env::var("HOSTNAME").ok().filter(|h| !h.is_empty() && !h.contains(' ')).unwrap_or_else(|| "memhouse".into());
        Exporter { store, cfg, service: service.to_string(), http: reqwest::Client::new(), holder: uuid::Uuid::new_v4().to_string(), host }
    }

    /// Take or renew the lease. One replica exports; a lease not renewed for a minute is free.
    async fn lead(&self) -> anyhow::Result<bool> {
        let now = Utc::now().timestamp();
        let mine = format!("{}|{}", self.holder, now + LEASE_SECS);
        let current = self.store.state_get("siem.lease").await?;
        let free = match current.as_deref().and_then(|c| c.split_once('|')) {
            None => true,
            Some((holder, until)) => holder == self.holder || until.parse::<i64>().map_or(true, |u| u < now),
        };
        if !free {
            return Ok(false);
        }
        self.store.state_cas("siem.lease", current.as_deref(), &mine).await
    }

    /// One pass: for each configured sink, send what the audit log holds after the sink's
    /// cursor, batch by batch, and move the cursor past what was taken.
    pub async fn pass(&self) -> anyhow::Result<Pass> {
        let mut pass = Pass { leader: self.lead().await?, ..Default::default() };
        if !pass.leader {
            return Ok(pass);
        }
        let sinks: Vec<&str> = [("syslog", &self.cfg.syslog), ("otlp", &self.cfg.otlp_endpoint)].into_iter().filter(|(_, t)| !t.trim().is_empty()).map(|(n, _)| n).collect();
        for sink in sinks {
            let key = format!("siem.cursor.{sink}");
            let mut cursor: i64 = match self.store.state_get(&key).await? {
                Some(c) => c.parse()?,
                None => {
                    // The export starts with the events written from now on.
                    let head = self.store.audit_head().await?.map_or(0, |h| h.id);
                    self.store.state_put(&key, &head.to_string()).await?;
                    head
                }
            };
            loop {
                let events = self.store.audit_after(cursor, self.cfg.batch.max(1)).await?;
                let Some(last) = events.last() else { break };
                let sent = match sink {
                    "syslog" => send_syslog(self.cfg.syslog.trim(), &events, &self.host).await,
                    _ => send_otlp(&self.http, &self.cfg, &events, &self.service).await,
                };
                if let Err(e) = sent {
                    pass.errors.push(format!("{sink}: {e:#}"));
                    break;
                }
                let now = Utc::now();
                pass.max_delay_ms = pass.max_delay_ms.max(events.iter().map(|e| (now - e.at).num_milliseconds()).max().unwrap_or(0));
                cursor = last.id;
                self.store.state_put(&key, &cursor.to_string()).await?;
                *pass.sent.entry(sink.to_string()).or_default() += events.len() as u64;
                if events.len() < self.cfg.batch.max(1) {
                    break;
                }
            }
        }
        // What the evidence export reports: when the export last ran, how far it is, what failed.
        self.store.state_put("siem.status", &json!({ "at": Utc::now(), "sent": pass.sent, "max_delay_ms": pass.max_delay_ms, "errors": pass.errors }).to_string()).await?;
        Ok(pass)
    }

    /// Run until cancelled.
    pub async fn run(self) {
        let every = Duration::from_secs(self.cfg.interval_secs.clamp(1, 30));
        let mut failing = false;
        loop {
            match self.pass().await {
                Ok(p) if p.errors.is_empty() => failing = false,
                // Said once per outage, not every few seconds.
                Ok(p) if !failing => {
                    failing = true;
                    tracing::warn!("SIEM export: {}; the events are kept and sent again", p.errors.join("; "));
                }
                Ok(_) => {}
                Err(e) if !failing => {
                    failing = true;
                    tracing::warn!("SIEM export: {e:#}");
                }
                Err(_) => {}
            }
            tokio::time::sleep(every).await;
        }
    }
}

/// How far each sink's cursor is behind the audit head, and the last pass: for the evidence export.
pub async fn status(store: &dyn Store, cfg: &SiemConfig) -> anyhow::Result<serde_json::Value> {
    let head = store.audit_head().await?;
    let mut sinks = serde_json::Map::new();
    for (sink, target) in [("syslog", &cfg.syslog), ("otlp", &cfg.otlp_endpoint)] {
        if target.trim().is_empty() {
            continue;
        }
        let cursor: Option<i64> = store.state_get(&format!("siem.cursor.{sink}")).await?.and_then(|c| c.parse().ok());
        sinks.insert(sink.into(), json!({ "cursor": cursor, "events_behind": head.as_ref().zip(cursor).map(|(h, c)| (h.id - c).max(0)) }));
    }
    let last: Option<serde_json::Value> = store.state_get("siem.status").await?.and_then(|s| serde_json::from_str(&s).ok());
    Ok(json!({
        "configured": cfg.enabled(), "interval_secs": cfg.interval_secs, "target_delay_secs": 60,
        "audit_head": head.map(|h| h.id), "sinks": sinks, "last_pass": last,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::DateTime;

    fn event() -> AuditEvent {
        AuditEvent {
            id: 42,
            at: DateTime::from_timestamp(1_795_000_000, 123_000_000).unwrap(),
            actor: "agent:bot|x".into(),
            action: "memory.write".into(),
            tenant: "acme".into(),
            subject: Some("customer:a=b".into()),
            memory_id: Some(uuid::Uuid::nil()),
            detail: json!({ "kind": "semantic", "note": "line\nbreak" }),
            prev_hash: "aa".into(),
            hash: "bb".into(),
        }
    }

    #[test]
    fn cef_escapes_what_would_break_the_message() {
        let c = cef(&event());
        assert!(c.starts_with(&format!("CEF:0|MemHouse|memhouse|{}|memory.write|memory.write|3|", env!("CARGO_PKG_VERSION"))), "{c}");
        assert!(c.contains("externalId=42") && c.contains("cs1Label=tenant cs1=acme"), "{c}");
        // `=` in a value is escaped, and the message stays one line.
        assert!(c.contains("cs2=customer:a\\=b"), "{c}");
        assert!(!c.contains('\n'), "{c}");
        let line = syslog_line(&event(), "host-1");
        assert!(line.starts_with("<110>1 2026-11-18T") && line.contains(" host-1 memhouse "), "{line}");
    }

    #[test]
    fn otlp_body_is_a_logs_request() {
        let b = otlp_body(&[event()], "memhouse");
        let r = &b["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0];
        assert_eq!(r["body"]["stringValue"], "memory.write");
        assert_eq!(r["severityNumber"], 9);
        assert_eq!(r["timeUnixNano"], "1795000000123000000");
        let attrs = r["attributes"].as_array().unwrap();
        assert!(attrs.iter().any(|a| a["key"] == "memhouse.audit.id" && a["value"]["intValue"] == "42"));
        assert!(attrs.iter().any(|a| a["key"] == "memhouse.audit.hash" && a["value"]["stringValue"] == "bb"));
    }

    #[test]
    fn refusals_are_warnings() {
        assert_eq!(severity("auth.failed"), 6);
        assert_eq!(severity("subject.erase"), 5);
        assert_eq!(severity("memory.write"), 3);
    }
}
