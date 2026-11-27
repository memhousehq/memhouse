// SPDX-License-Identifier: Apache-2.0
//! SIEM export (GOV-15): every audit event, in order, to a syslog receiver as CEF and to an
//! OpenTelemetry collector as OTLP logs, within seconds of being written.
//!
//! The exporter reads the audit log after a cursor it keeps in the store, sends a batch, and
//! advances the cursor once the send succeeded here: a collector's 2xx answer over OTLP, the
//! bytes written and the connection closed without error over TCP syslog, the datagrams sent
//! over UDP. A send that fails is repeated, so a sink that is down delays its events; what a
//! sink does after it accepted the bytes is not known here (syslog has no acknowledgement).
//! The cursor also moves past an event a collector refuses for good (HTTP 400, 413 or 422 for
//! the event alone) and past log records it rejects in a partial success: those are named or
//! counted in the pass and its status, and are not sent again. With several replicas one
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
    // Bounded, with the connect above, well inside the lease: a receiver that stops reading
    // cannot hold a pass in a write until another replica has taken the export over and sent
    // the same events. A write cut short leaves part of the batch at the receiver, and the
    // whole batch is sent again: after such a failure a receiver may see events twice.
    tokio::time::timeout(SYSLOG_WRITE, async {
        stream.write_all(out.as_bytes()).await?;
        stream.flush().await?;
        stream.shutdown().await
    })
    .await
    .map_err(|_| anyhow::anyhow!("writing to {addr} timed out after {} s", SYSLOG_WRITE.as_secs()))??;
    Ok(())
}

/// The longest a batch may take to be written to a TCP syslog receiver. With the ten seconds
/// to connect it stays under half of [`LEASE_SECS`].
const SYSLOG_WRITE: Duration = Duration::from_secs(15);

/// The log records of a batch a collector said it rejected in an answer that is otherwise a
/// success (OTLP partial success): `partialSuccess.rejectedLogRecords`, a number or a string.
fn rejected_records(body: &str) -> u64 {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else { return 0 };
    let n = &v["partialSuccess"]["rejectedLogRecords"];
    n.as_u64().or_else(|| n.as_str().and_then(|s| s.parse().ok())).unwrap_or(0)
}

/// A target as it is named in errors, logs and the export's status: scheme, host and port.
/// Whatever else a URL holds (a user, a password, a path, a query) is not repeated.
pub fn target_name(url: &str) -> String {
    let (scheme, rest) = url.trim().split_once("://").unwrap_or(("", url.trim()));
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or("");
    format!("{scheme}://{host}")
}

/// A send that failed: `permanent` when the receiver refused the payload itself, so that
/// sending the same payload again cannot succeed.
struct SendError {
    message: String,
    permanent: bool,
}

/// Send a batch to the collector. Returns how many of its log records the collector rejected
/// while accepting the rest.
async fn send_otlp(http: Option<&reqwest::Client>, cfg: &SiemConfig, events: &[AuditEvent], service: &str) -> Result<u64, SendError> {
    // No client, no send: there is no falling back to one that follows redirects.
    let http = http.ok_or_else(|| SendError { message: "OTLP export: the HTTP client could not be set up".into(), permanent: false })?;
    let url = format!("{}/v1/logs", cfg.otlp_endpoint.trim().trim_end_matches('/'));
    let to = target_name(&url);
    let mut req = http.post(&url).timeout(Duration::from_secs(15)).json(&otlp_body(events, service));
    for (name, var) in &cfg.otlp_headers_env {
        // The value is read from the environment for this request and goes nowhere else.
        let value =
            std::env::var(var).map_err(|_| SendError { message: format!("siem.otlp_headers_env: the environment variable {var} (header {name}) is not set"), permanent: false })?;
        req = req.header(name, value);
    }
    let resp = req.send().await.map_err(|e| SendError { message: format!("OTLP export to {to}: {}", e.without_url()), permanent: false })?;
    let status = resp.status();
    if status.is_success() {
        // A success may still say that some records were rejected. They are not sent again
        // (OTLP forbids repeating a partially accepted request); the caller counts them.
        let rejected = rejected_records(&resp.text().await.unwrap_or_default()).min(events.len() as u64);
        return Ok(rejected);
    }
    // A redirect is not followed (it would resend the headers elsewhere, or turn the POST into
    // a GET): it is a failure to be fixed in the configuration, as a refused credential or a
    // wrong path is (401, 403, 404): those are retried, and lose nothing. Only an answer about
    // the payload itself (malformed, too large, unprocessable) counts as the receiver refusing
    // these events.
    let permanent = matches!(status.as_u16(), 400 | 413 | 422);
    Err(SendError { message: format!("OTLP export to {to}: HTTP {status}"), permanent })
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
    /// Events a receiver refused even alone (by audit id, in `errors`): skipped, so that one
    /// event the receiver will never take does not hold back every later one.
    pub skipped: u64,
}

/// The exporter of one process.
pub struct Exporter {
    store: Arc<dyn Store>,
    cfg: SiemConfig,
    service: String,
    /// None if it could not be built: the OTLP sink then fails every pass, and says so.
    http: Option<reqwest::Client>,
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
        // No redirects: one would carry the configured headers to another host, or replay the
        // POST as a GET without its events and report them delivered.
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| tracing::error!("SIEM export: the HTTP client could not be set up: {e}"))
            .ok();
        Exporter { store, cfg, service: service.to_string(), http, holder: uuid::Uuid::new_v4().to_string(), host }
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
                    // The export starts with the events written from now on. Set only if still
                    // unset: a replica that set it first is not overwritten.
                    let head = self.store.audit_head().await?.map_or(0, |h| h.id);
                    if !self.store.state_cas(&key, None, &head.to_string()).await? {
                        pass.errors.push(format!("{sink}: the cursor was set by another replica; this pass left it"));
                        continue;
                    }
                    head
                }
            };
            let full = self.cfg.batch.max(1);
            let mut size = full;
            'batches: loop {
                // The lease is renewed before every batch: a pass that outlives it stops here,
                // and leaves the cursor to the replica that took over.
                if !self.lead().await? {
                    pass.errors.push(format!("{sink}: another replica took over the export during this pass"));
                    break;
                }
                let events = self.store.audit_after(cursor, size).await?;
                let Some(last) = events.last() else { break };
                let sent = match sink {
                    "syslog" => send_syslog(self.cfg.syslog.trim(), &events, &self.host).await.map(|()| 0).map_err(|e| SendError { message: format!("{e:#}"), permanent: false }),
                    _ => send_otlp(self.http.as_ref(), &self.cfg, &events, &self.service).await,
                };
                let mut delivered = events.len() as u64;
                match sent {
                    Ok(0) => {}
                    // Accepted in part: what the collector rejected is counted, not sent again.
                    Ok(rejected) => {
                        tracing::error!("SIEM export: {sink} rejected {rejected} of the {} log records up to audit event {}; they are not sent again", events.len(), last.id);
                        pass.errors.push(format!("{sink}: {rejected} of {} log records up to audit event {} rejected by the collector and skipped", events.len(), last.id));
                        pass.skipped += rejected;
                        delivered -= rejected;
                    }
                    // The receiver refuses this payload: tried in halves, down to one event.
                    Err(e) if e.permanent && events.len() > 1 => {
                        size = (events.len() / 2).max(1);
                        continue 'batches;
                    }
                    // One event the receiver will not take: on record here and in the log
                    // with its audit id, and passed over, or nothing after it would ever go.
                    Err(e) if e.permanent => {
                        tracing::error!(audit_id = last.id, "SIEM export: {sink} refused audit event {} ({}); it is skipped", last.id, e.message);
                        pass.errors.push(format!("{sink}: audit event {} refused and skipped ({})", last.id, e.message));
                        pass.skipped += 1;
                        delivered = 0;
                    }
                    Err(e) => {
                        pass.errors.push(format!("{sink}: {}", e.message));
                        break;
                    }
                }
                let now = Utc::now();
                if delivered > 0 {
                    pass.max_delay_ms = pass.max_delay_ms.max(events.iter().map(|e| (now - e.at).num_milliseconds()).max().unwrap_or(0));
                }
                // Moved only from where this pass left it: if another replica moved it
                // meanwhile, this pass ends without writing an older position over a newer one.
                let next = last.id.to_string();
                if !self.store.state_cas(&key, Some(&cursor.to_string()), &next).await? {
                    pass.errors.push(format!("{sink}: the cursor was moved by another replica; this pass stopped"));
                    break;
                }
                cursor = last.id;
                *pass.sent.entry(sink.to_string()).or_default() += delivered;
                if events.len() < size {
                    break;
                }
                // Back to whole batches after one that had to be split.
                size = full;
            }
        }
        // What the evidence export reports: when the export last ran, how far it is, what failed.
        self.store
            .state_put(
                "siem.status",
                &json!({ "at": Utc::now(), "sent": pass.sent, "max_delay_ms": pass.max_delay_ms, "errors": pass.errors, "skipped": pass.skipped }).to_string(),
            )
            .await?;
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
    fn a_partial_success_is_read() {
        assert_eq!(rejected_records(r#"{"partialSuccess":{"rejectedLogRecords":"3","errorMessage":"x"}}"#), 3);
        assert_eq!(rejected_records(r#"{"partialSuccess":{"rejectedLogRecords":2}}"#), 2);
        assert_eq!((rejected_records("{}"), rejected_records(""), rejected_records(r#"{"partialSuccess":{}}"#)), (0, 0, 0));
    }

    /// One HTTP exchange: read the request, answer with `response`.
    async fn answer_once(response: &'static str) -> std::net::SocketAddr {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = vec![0u8; 65536];
                let mut read = 0;
                // The head and a body of the length it names.
                loop {
                    let n = stream.read(&mut buf[read..]).await.unwrap_or(0);
                    read += n;
                    let text = String::from_utf8_lossy(&buf[..read]).to_ascii_lowercase();
                    let done = text.split_once("\r\n\r\n").is_some_and(|(head, body)| {
                        body.len() >= head.lines().find_map(|l| l.strip_prefix("content-length:")).and_then(|v| v.trim().parse::<usize>().ok()).unwrap_or(0)
                    });
                    if n == 0 || done {
                        break;
                    }
                }
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });
        addr
    }

    #[tokio::test]
    async fn a_redirect_is_a_failed_send_and_a_partial_success_is_counted() {
        let http = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).build().unwrap();
        let cfg = |addr: std::net::SocketAddr| SiemConfig { otlp_endpoint: format!("http://{addr}"), ..Default::default() };
        // A redirect is not followed: the send fails, to be tried again, and nothing counts as delivered.
        let moved = answer_once("HTTP/1.1 307 Temporary Redirect\r\nlocation: http://127.0.0.1:9/elsewhere\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").await;
        let Err(e) = send_otlp(Some(&http), &cfg(moved), &[event()], "memhouse").await else { panic!("a redirect is not a delivery") };
        assert!(!e.permanent && e.message.contains("307") && !e.message.contains("elsewhere"), "{}", e.message);
        // Without a client nothing is sent.
        assert!(send_otlp(None, &cfg(moved), &[event()], "memhouse").await.is_err());
        // A success that rejects one of two records.
        let body = r#"{"partialSuccess":{"rejectedLogRecords":"1"}}"#;
        let partial: &'static str =
            Box::leak(format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).into_boxed_str());
        let ok = answer_once(partial).await;
        assert_eq!(send_otlp(Some(&http), &cfg(ok), &[event(), event()], "memhouse").await.ok(), Some(1));
    }

    #[test]
    fn a_target_is_named_without_what_a_url_may_carry() {
        assert_eq!(target_name("https://user:pw@collector.internal:4318/v1/logs?token=abc"), "https://collector.internal:4318"); // secret-scan: allow (fake fixture)
        assert_eq!(target_name("http://127.0.0.1:4318/v1/logs"), "http://127.0.0.1:4318");
    }

    #[test]
    fn refusals_are_warnings() {
        assert_eq!(severity("auth.failed"), 6);
        assert_eq!(severity("subject.erase"), 5);
        assert_eq!(severity("memory.write"), 3);
    }
}
