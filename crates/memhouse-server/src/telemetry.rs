// SPDX-License-Identifier: Apache-2.0
//! Logs and traces (QUAL-07, TR-OPS-06). Spans always exist in-process (they cost next to nothing
//! without a subscriber that records them); with `[telemetry] otlp_endpoint` set they are also
//! exported over OTLP/HTTP to any OpenTelemetry backend: a collector, Jaeger, Tempo, Honeycomb, or
//! an LLM-observability tool such as Langfuse (enrichment calls carry `gen_ai.*` attributes).
//! Spans hold identifiers, counts and timings, never memory content (PR-3).

use memhouse_core::config::TelemetryConfig;
use opentelemetry::trace::TracerProvider as _;
use opentelemetry_otlp::{WithExportConfig, WithHttpConfig};
use opentelemetry_sdk::trace::{Sampler, SdkTracerProvider};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

/// Which spans are exported: MemHouse's own and the HTTP layer's, at info. `MEMHOUSE_OTLP_FILTER`
/// overrides it with an `EnvFilter` directive (e.g. `info,sqlx=warn`).
pub const SPAN_TARGETS: [&str; 5] = ["memhouse_core", "memhouse_server", "memhouse_store_postgres", "memhouse_models", "tower_http"];

/// Whether a span or event is one of ours, at info or above.
fn own_span(meta: &tracing::Metadata<'_>) -> bool {
    *meta.level() <= tracing::Level::INFO && SPAN_TARGETS.iter().any(|t| meta.target() == *t || meta.target().strip_prefix(t).is_some_and(|r| r.starts_with("::")))
}

/// Keeps the exporter alive; flushes pending spans when dropped.
pub struct Telemetry {
    provider: Option<SdkTracerProvider>,
}

impl Drop for Telemetry {
    fn drop(&mut self) {
        if let Some(p) = self.provider.take() {
            let _ = p.shutdown();
        }
    }
}

/// `k=v,k2=v2`, the format of `OTEL_EXPORTER_OTLP_HEADERS`.
fn parse_headers(s: &str) -> Vec<(String, String)> {
    s.split(',').filter_map(|kv| kv.split_once('=')).map(|(k, v)| (k.trim().to_string(), v.trim().replace("%20", " "))).filter(|(k, _)| !k.is_empty()).collect()
}

/// The signal path for traces: `<endpoint>/v1/traces`, unless the endpoint already names it.
fn traces_url(endpoint: &str) -> String {
    let e = endpoint.trim_end_matches('/');
    if e.ends_with("/v1/traces") {
        e.to_string()
    } else {
        format!("{e}/v1/traces")
    }
}

/// Install the global subscriber: logs to stderr filtered by `log_filter`, and, when configured,
/// spans of MemHouse's own crates to the OTLP exporter.
pub fn init(cfg: &TelemetryConfig, log_filter: &str) -> anyhow::Result<Telemetry> {
    if cfg.otlp_endpoint.trim().is_empty() {
        tracing_subscriber::registry().with(tracing_subscriber::fmt::layer().with_writer(std::io::stderr).with_filter(EnvFilter::new(log_filter))).try_init()?;
        return Ok(Telemetry { provider: None });
    }
    let mut headers: std::collections::HashMap<String, String> = cfg.otlp_headers.clone().into_iter().collect();
    if let Ok(h) = std::env::var("OTEL_EXPORTER_OTLP_HEADERS") {
        headers.extend(parse_headers(&h));
    }
    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_http()
        .with_endpoint(traces_url(&cfg.otlp_endpoint))
        .with_protocol(opentelemetry_otlp::Protocol::HttpBinary)
        .with_headers(headers)
        .build()?;
    let resource = opentelemetry_sdk::Resource::builder()
        .with_service_name(cfg.service_name.clone())
        .with_attribute(opentelemetry::KeyValue::new("service.version", env!("CARGO_PKG_VERSION")))
        .build();
    let provider = SdkTracerProvider::builder()
        .with_batch_exporter(exporter)
        .with_resource(resource)
        .with_sampler(Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(cfg.sample_ratio.clamp(0.0, 1.0)))))
        .build();
    // One global filter (the log directives plus MemHouse's spans at info); the exporter narrows
    // it to MemHouse's own spans. A second per-layer filter on the log layer made the exporter
    // lose spans in practice (tracing-subscriber 0.3), so the log layer has none.
    let global = EnvFilter::new(format!("{log_filter},{}", SPAN_TARGETS.iter().map(|t| format!("{t}=info")).collect::<Vec<_>>().join(",")));
    let spans = tracing_opentelemetry::layer().with_tracer(provider.tracer("memhouse"));
    match std::env::var("MEMHOUSE_OTLP_FILTER") {
        Ok(f) => {
            tracing_subscriber::registry().with(global).with(tracing_subscriber::fmt::layer().with_writer(std::io::stderr)).with(spans.with_filter(EnvFilter::new(f))).try_init()?
        }
        Err(_) => tracing_subscriber::registry()
            .with(global)
            .with(tracing_subscriber::fmt::layer().with_writer(std::io::stderr))
            .with(spans.with_filter(tracing_subscriber::filter::filter_fn(own_span)))
            .try_init()?,
    }
    Ok(Telemetry { provider: Some(provider) })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Cs;
    impl tracing::callsite::Callsite for Cs {
        fn set_interest(&self, _: tracing::subscriber::Interest) {}
        fn metadata(&self) -> &tracing::Metadata<'_> {
            unimplemented!()
        }
    }
    static CS: Cs = Cs;

    #[test]
    fn otlp_settings() {
        assert_eq!(traces_url("http://localhost:4318/"), "http://localhost:4318/v1/traces");
        assert_eq!(traces_url("https://cloud.langfuse.com/api/public/otel"), "https://cloud.langfuse.com/api/public/otel/v1/traces");
        assert_eq!(traces_url("http://c:4318/v1/traces"), "http://c:4318/v1/traces");
        assert_eq!(parse_headers("Authorization=Basic%20abc, x-k = v"), vec![("Authorization".into(), "Basic abc".into()), ("x-k".into(), "v".into())]);
        let meta = |target: &'static str| {
            tracing::Metadata::new(
                "s",
                target,
                tracing::Level::INFO,
                None,
                None,
                None,
                tracing::field::FieldSet::new(&[], tracing::callsite::Identifier(&CS)),
                tracing::metadata::Kind::SPAN,
            )
        };
        assert!(own_span(&meta("memhouse_core::engine")) && own_span(&meta("memhouse_store_postgres")));
        assert!(!own_span(&meta("memhouse_core_extra")) && !own_span(&meta("sqlx::query")));
    }
}
