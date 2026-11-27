// SPDX-License-Identifier: Apache-2.0
//! The admin console's side of the HTTP gateway (G20, threat model T3): the pages, the session
//! cookie, the CSRF and origin rules for requests made with it, and the CORS allow-list.
//!
//! The console is three static files. They call the same API as every client, as the
//! principal that logged in, so the server decides every action and the pages hold no rule of
//! their own. What is here protects the session:
//!
//! - the key is presented once (`POST /v1/session`); the browser keeps only a session secret
//!   in an `HttpOnly`, `SameSite=Strict` cookie that script cannot read;
//! - a request made with the cookie must come from the server's own origin, and one that
//!   changes something must carry the session's CSRF token;
//! - the pages are served with a Content-Security-Policy that allows no inline script and no
//!   inline style, and no source but the server itself;
//! - pages of other origins may call the API only when the origin is on
//!   `[server] cors_origins`, and then with a key or token of their own, never the cookie.

use crate::{ApiError, AppState, Who};
use axum::extract::{Request, State};
use axum::http::header::{self, HeaderName};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::Json;
use memhouse_core::admin::{SessionClosed, SessionInfo};
use memhouse_core::config::{Config, CookieSecure};
use memhouse_core::error::{self, ErrorBody, ErrorCode};
use memhouse_core::identity::SESSION_PREFIX;

/// The session cookie over TLS. The `__Host-` prefix makes browsers refuse it unless it is
/// `Secure`, has `Path=/` and no `Domain`, so a sibling host cannot set or overwrite it.
pub const COOKIE_SECURE: &str = "__Host-memhouse_session";
/// The session cookie on a loopback host, where there is no TLS to require.
pub const COOKIE_PLAIN: &str = "memhouse_session";
/// The header that carries the session's CSRF token.
pub const CSRF_HEADER: &str = "x-memhouse-csrf";

/// The policy the console's pages are served with: nothing from anywhere but this server, no
/// inline script, no inline style (`style` attributes included), no framing, no plugins.
pub const CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; \
     base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

const HTML: &str = include_str!("console/console.html");
const CSS: &str = include_str!("console/console.css");
const JS: &str = include_str!("console/console.js");

/// The files of the console by the path each is served at.
pub const ASSETS: [(&str, &str, &str); 3] =
    [("/", "text/html; charset=utf-8", HTML), ("/console.css", "text/css; charset=utf-8", CSS), ("/console.js", "text/javascript; charset=utf-8", JS)];

/// The session of a request that was authenticated by its cookie.
#[derive(Clone)]
pub struct SessionCtx {
    pub secret: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

/// `host[:port]` without a trailing dot, lower case.
fn authority(v: &str) -> String {
    v.trim().trim_end_matches('.').to_ascii_lowercase()
}

/// The authorities this server is reached at for a request: its `Host`, and the host a
/// reverse proxy says it forwarded (`X-Forwarded-Host`). A page cannot set either header on
/// a request from a visitor's browser, so they are safe to compare an `Origin` against.
fn own_authorities(headers: &HeaderMap) -> Vec<String> {
    let mut out = vec![];
    for name in [header::HOST.as_str(), "x-forwarded-host"] {
        for v in headers.get_all(name).iter().filter_map(|v| v.to_str().ok()) {
            out.extend(v.split(',').map(authority).filter(|a| !a.is_empty()));
        }
    }
    out
}

/// The authority of an `Origin` value (`https://host:port`), or `None` for `null` and
/// anything that is not an origin.
fn origin_authority(origin: &str) -> Option<String> {
    let rest = origin.strip_prefix("https://").or_else(|| origin.strip_prefix("http://"))?;
    (!rest.is_empty() && !rest.contains('/')).then(|| authority(rest))
}

/// Whether a request's `Origin` is this server itself. Default ports are compared as written:
/// a browser leaves `:443` out of both `Origin` and `Host`.
pub fn same_origin(headers: &HeaderMap, origin: &str) -> bool {
    origin_authority(origin).is_some_and(|a| own_authorities(headers).contains(&a))
}

fn loopback(host: &str) -> bool {
    let h = authority(host);
    let name = if let Some(rest) = h.strip_prefix('[') { rest.split(']').next().unwrap_or("") } else { h.rsplit_once(':').map_or(h.as_str(), |(n, _)| n) };
    name == "localhost" || name.ends_with(".localhost") || name == "::1" || name.parse::<std::net::Ipv4Addr>().is_ok_and(|ip| ip.is_loopback())
}

/// Whether the session cookie of this request is the `Secure` one (`[server]
/// session_cookie_secure`). `auto`: always, except for a request to a loopback host, where
/// browsers other than Chrome and Firefox do not send a `Secure` cookie over plain HTTP. A
/// request without a `Host` is treated as not loopback.
pub fn cookie_secure(cfg: &Config, headers: &HeaderMap) -> bool {
    match cfg.server.session_cookie_secure {
        CookieSecure::Always => true,
        CookieSecure::Never => false,
        CookieSecure::Auto => !headers.get(header::HOST).and_then(|v| v.to_str().ok()).is_some_and(loopback),
    }
}

fn cookie_name(secure: bool) -> &'static str {
    if secure {
        COOKIE_SECURE
    } else {
        COOKIE_PLAIN
    }
}

/// The session secret a request carries: the cookie of the name this request's rule gives,
/// and no other, so a cookie planted under the plain name is not read on a TLS deployment.
pub fn session_cookie(cfg: &Config, headers: &HeaderMap) -> Option<String> {
    let name = cookie_name(cookie_secure(cfg, headers));
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(k, v)| *k == name && v.starts_with(SESSION_PREFIX))
        .map(|(_, v)| v.to_string())
}

fn set_cookie(secure: bool, value: &str, max_age: u64) -> HeaderValue {
    let mut c = format!("{}={value}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age}", cookie_name(secure));
    if secure {
        c.push_str("; Secure");
    }
    HeaderValue::from_str(&c).unwrap_or(HeaderValue::from_static(""))
}

fn refusal(status: StatusCode, code: ErrorCode, message: &str) -> Response {
    (status, Json(ErrorBody { error: message.into(), code })).into_response()
}

/// Why a request made with the session cookie is refused before it runs, if it is: it names
/// another origin, or it changes something without the session's CSRF token. `None`: go on.
pub fn guard(headers: &HeaderMap, method: &Method, secret: &str) -> Option<&'static str> {
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) {
        if !same_origin(headers, origin) {
            return Some("a session is used from the console's own origin only");
        }
    }
    if headers.get("sec-fetch-site").and_then(|v| v.to_str().ok()).is_some_and(|v| v == "cross-site") {
        return Some("a session is used from the console's own origin only");
    }
    if matches!(*method, Method::GET | Method::HEAD | Method::OPTIONS) {
        return None;
    }
    let sent = headers.get(CSRF_HEADER).and_then(|v| v.to_str().ok()).unwrap_or("");
    let want = memhouse_core::identity::csrf_token(secret);
    if memhouse_core::identity::constant_time_eq(sent.as_bytes(), want.as_bytes()) {
        None
    } else {
        Some("this request changes something with a session and needs the session's x-memhouse-csrf token")
    }
}

/// Cross-origin requests (T3). A request without `Origin`, or from this server's own origin,
/// passes untouched. One from an origin on `[server] cors_origins` is answered with that
/// origin allowed, never `*` and never with credentials. Any other origin is refused before
/// anything runs, preflight or not.
pub(crate) async fn cors(State(st): State<AppState>, req: Request, next: Next) -> Response {
    let Some(origin) = req.headers().get(header::ORIGIN).and_then(|v| v.to_str().ok()).map(String::from) else {
        return next.run(req).await;
    };
    if same_origin(req.headers(), &origin) {
        return next.run(req).await;
    }
    let listed = st.engine.cfg.server.cors_origins.iter().any(|o| o != "*" && o.trim_end_matches('/').eq_ignore_ascii_case(&origin));
    if !listed {
        memhouse_core::metrics::inc("memhouse_refused_total", &[("kind", "cors"), ("reason", "origin")], 1.0);
        let mut resp = refusal(StatusCode::FORBIDDEN, ErrorCode::Forbidden, "this origin may not call the API from a browser (see [server] cors_origins)");
        resp.headers_mut().insert(header::VARY, HeaderValue::from_static("Origin"));
        return resp;
    }
    let preflight = req.method() == Method::OPTIONS && req.headers().contains_key(header::ACCESS_CONTROL_REQUEST_METHOD);
    let mut resp = if preflight { StatusCode::NO_CONTENT.into_response() } else { next.run(req).await };
    let h = resp.headers_mut();
    if let Ok(v) = HeaderValue::from_str(&origin) {
        h.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, v);
    }
    h.append(header::VARY, HeaderValue::from_static("Origin"));
    if preflight {
        h.insert(header::ACCESS_CONTROL_ALLOW_METHODS, HeaderValue::from_static("GET, POST, PUT, PATCH, DELETE"));
        h.insert(header::ACCESS_CONTROL_ALLOW_HEADERS, HeaderValue::from_static("authorization, content-type, idempotency-key, x-api-key, x-memhouse-user"));
        h.insert(header::ACCESS_CONTROL_MAX_AGE, HeaderValue::from_static("600"));
    }
    resp
}

/// Headers every response carries: no MIME sniffing, no framing, no referrer.
pub async fn security_headers(req: Request, next: Next) -> Response {
    let mut resp = next.run(req).await;
    let h = resp.headers_mut();
    h.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    h.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    h.insert(header::REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    resp
}

/// One of the console's files, with the Content-Security-Policy.
fn asset(st: &AppState, path: &str) -> Response {
    let Some((_, content_type, body)) = ASSETS.iter().find(|(p, _, _)| *p == path).filter(|_| st.engine.cfg.server.console) else {
        return ApiError(error::not_found("no such route")).into_response();
    };
    (
        [
            (header::CONTENT_TYPE, HeaderValue::from_static(content_type)),
            (header::CONTENT_SECURITY_POLICY, HeaderValue::from_static(CSP)),
            // Revalidated on each load: an upgraded server never runs with an old page.
            (header::CACHE_CONTROL, HeaderValue::from_static("no-cache")),
            (HeaderName::from_static("cross-origin-opener-policy"), HeaderValue::from_static("same-origin")),
            (HeaderName::from_static("cross-origin-resource-policy"), HeaderValue::from_static("same-origin")),
        ],
        *body,
    )
        .into_response()
}

pub(crate) async fn page(State(st): State<AppState>) -> Response {
    asset(&st, "/")
}

pub(crate) async fn stylesheet(State(st): State<AppState>) -> Response {
    asset(&st, "/console.css")
}

pub(crate) async fn script(State(st): State<AppState>) -> Response {
    asset(&st, "/console.js")
}

fn no_store(mut resp: Response) -> Response {
    resp.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    resp
}

/// Log in: the request presents a key as every API request does; the answer sets the session
/// cookie. The key is not kept by the page, and the session secret is not in the body.
pub(crate) async fn session_open(State(st): State<AppState>, Who(c): Who, headers: HeaderMap) -> Result<Response, ApiError> {
    // Asked with a session's cookie: refused by the engine, which names the reason.
    let presented = crate::credential(&headers).unwrap_or_default();
    let (secret, info) = c.session_open(&presented).await?;
    let secure = cookie_secure(&st.engine.cfg, &headers);
    let max_age = (info.expires_at - chrono::Utc::now()).num_seconds().max(1) as u64;
    let mut resp = Json(info).into_response();
    resp.headers_mut().append(header::SET_COOKIE, set_cookie(secure, &secret, max_age));
    Ok(no_store(resp))
}

/// The session of this request: who it acts as, until when, and its CSRF token.
pub(crate) async fn session_get(Who(c): Who, req: Request) -> Result<Response, ApiError> {
    c.session_allowed().await?;
    let ctx = req.extensions().get::<SessionCtx>().cloned().ok_or_else(|| ApiError(error::not_found("no session: this request was not made with a session cookie")))?;
    let info: SessionInfo = c.session_info(&ctx.secret, ctx.expires_at);
    Ok(no_store(Json(info).into_response()))
}

/// Log out: the session ends on the server and the cookie is cleared.
pub(crate) async fn session_close(State(st): State<AppState>, Who(c): Who, req: Request) -> Result<Response, ApiError> {
    c.session_allowed().await?;
    let ctx = req.extensions().get::<SessionCtx>().cloned().ok_or_else(|| ApiError(error::not_found("no session: this request was not made with a session cookie")))?;
    let closed: SessionClosed = c.session_close(&ctx.secret).await?;
    let secure = cookie_secure(&st.engine.cfg, req.headers());
    let mut resp = Json(closed).into_response();
    resp.headers_mut().append(header::SET_COOKIE, set_cookie(secure, "", 0));
    Ok(no_store(resp))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.append(HeaderName::from_bytes(k.as_bytes()).unwrap(), HeaderValue::from_str(v).unwrap());
        }
        h
    }

    /// The pages run under a policy without inline script or style, so they must contain
    /// none: no `<script>` with a body, no `<style>`, no `style=` or `on…=` attribute, no
    /// `javascript:` URL; and everything they load is a file this server serves.
    #[test]
    fn pages_have_no_inline_script_or_style_and_load_only_served_files() {
        let lower = HTML.to_ascii_lowercase();
        assert!(!lower.contains("<style"), "inline <style>");
        assert!(!lower.contains("javascript:"), "javascript: URL");
        let mut rest = lower.as_str();
        while let Some(at) = rest.find('<') {
            let tag = &rest[at..rest[at..].find('>').map_or(rest.len(), |e| at + e + 1)];
            assert!(!tag.contains(" style="), "inline style attribute: {tag}");
            let handler = tag
                .split_whitespace()
                .any(|w| w.starts_with("on") && w.contains('=') && w.split('=').next().is_some_and(|n| n.len() > 2 && n.chars().all(|c| c.is_ascii_lowercase())));
            assert!(!handler, "inline event handler: {tag}");
            if tag.starts_with("<script") {
                let src = tag.split("src=\"").nth(1).and_then(|s| s.split('"').next()).unwrap_or_else(|| panic!("a script without src: {tag}"));
                assert!(ASSETS.iter().any(|(p, t, _)| *p == src && t.starts_with("text/javascript")), "script {src} is not served");
                let after = &rest[at + tag.len()..];
                assert!(after.trim_start().starts_with("</script>"), "a script with a body");
            }
            if tag.starts_with("<link") {
                let href = tag.split("href=\"").nth(1).and_then(|s| s.split('"').next()).unwrap_or_default();
                assert!(ASSETS.iter().any(|(p, _, _)| *p == href), "link {href} is not served");
            }
            rest = &rest[at + tag.len()..];
        }
        // The script builds the page from data with DOM calls: no HTML from strings, no eval,
        // and nothing kept in the browser's storage (T3: no key or session id there).
        for banned in [
            "innerHTML",
            "outerHTML",
            "insertAdjacentHTML",
            "document.write",
            "eval(",
            "new Function",
            "localStorage",
            "sessionStorage",
            "document.cookie",
            "setAttribute(\"style\"",
            ".style.",
        ] {
            assert!(!JS.contains(banned), "console.js uses {banned}");
        }
        assert!(!CSP.contains("unsafe-inline") && !CSP.contains("unsafe-eval") && CSP.contains("script-src 'self'") && CSP.contains("style-src 'self'"));
    }

    #[test]
    fn cookie_name_and_flags_follow_the_host() {
        let cfg = Config::default();
        for (host, secure) in [
            ("localhost:7077", false),
            ("127.0.0.1:7077", false),
            ("[::1]:7077", false),
            ("app.localhost", false),
            ("memhouse.example.com", true),
            ("10.0.0.5:7077", true),
            ("localhost.example.com", true),
        ] {
            assert_eq!(cookie_secure(&cfg, &headers(&[("host", host)])), secure, "{host}");
        }
        assert!(cookie_secure(&cfg, &HeaderMap::new()), "no Host: not loopback");
        let c = set_cookie(true, "mhs_x", 60);
        let c = c.to_str().unwrap();
        assert!(
            c.starts_with("__Host-memhouse_session=mhs_x; ")
                && c.contains("HttpOnly")
                && c.contains("SameSite=Strict")
                && c.contains("Path=/")
                && c.ends_with("; Secure")
                && !c.contains("Domain")
        );
        let p = set_cookie(false, "mhs_x", 60);
        assert!(p.to_str().unwrap().starts_with("memhouse_session=mhs_x; ") && !p.to_str().unwrap().contains("Secure"));
        // Only the cookie of the request's own rule is read.
        let tls = headers(&[("host", "memhouse.example.com"), ("cookie", "memhouse_session=mhs_planted; other=1")]);
        assert_eq!(session_cookie(&cfg, &tls), None);
        let tls = headers(&[("host", "memhouse.example.com"), ("cookie", "a=b; __Host-memhouse_session=mhs_real")]);
        assert_eq!(session_cookie(&cfg, &tls).as_deref(), Some("mhs_real"));
        let local = headers(&[("host", "localhost:7077"), ("cookie", "memhouse_session=mhs_local")]);
        assert_eq!(session_cookie(&cfg, &local).as_deref(), Some("mhs_local"));
        let mut never = Config::default();
        never.server.session_cookie_secure = CookieSecure::Never;
        assert!(!cookie_secure(&never, &headers(&[("host", "memhouse.example.com")])));
    }

    #[test]
    fn a_session_request_needs_its_own_origin_and_the_csrf_token() {
        let secret = "mhs_secret";
        let token = memhouse_core::identity::csrf_token(secret);
        let own = [("host", "memhouse.example.com"), ("origin", "https://memhouse.example.com")];
        assert_eq!(guard(&headers(&own), &Method::GET, secret), None);
        assert!(guard(&headers(&own), &Method::POST, secret).unwrap().contains("csrf"));
        let mut with = own.to_vec();
        with.push((CSRF_HEADER, &token));
        assert_eq!(guard(&headers(&with), &Method::POST, secret), None);
        assert_eq!(guard(&headers(&with), &Method::DELETE, secret), None);
        // The token of another session is not this one's.
        let other = memhouse_core::identity::csrf_token("mhs_other");
        assert!(guard(&headers(&[("host", "h"), (CSRF_HEADER, &other)]), &Method::POST, secret).is_some());
        // Another origin is refused even for a read and even with the token.
        let foreign = [("host", "memhouse.example.com"), ("origin", "https://evil.example"), (CSRF_HEADER, token.as_str())];
        assert!(guard(&headers(&foreign), &Method::GET, secret).unwrap().contains("own origin"));
        assert!(guard(&headers(&foreign), &Method::POST, secret).is_some());
        assert!(guard(&headers(&[("host", "h"), ("origin", "null")]), &Method::GET, secret).is_some());
        assert!(guard(&headers(&[("host", "h"), ("sec-fetch-site", "cross-site")]), &Method::GET, secret).is_some());
        // Behind a proxy that names the public host.
        let proxied = [("host", "127.0.0.1:7077"), ("x-forwarded-host", "memhouse.example.com"), ("origin", "https://memhouse.example.com")];
        assert_eq!(guard(&headers(&proxied), &Method::GET, secret), None);
        assert!(same_origin(&headers(&[("host", "LocalHost:7077")]), "http://localhost:7077"));
        assert!(!same_origin(&headers(&[("host", "localhost:7077")]), "http://localhost:7078"));
    }
}
