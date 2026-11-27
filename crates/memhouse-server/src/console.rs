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
//! - a request made with the cookie must come from the server's own origin (scheme, host and
//!   port; `Sec-Fetch-Site: same-origin` where the browser says), and one that changes
//!   something must carry the session's CSRF token;
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

/// An origin as `(scheme, authority)`, the scheme's default port left out, or `None` for
/// `null` and anything that is not an `http` or `https` origin.
fn origin_parts(origin: &str) -> Option<(&'static str, String)> {
    let (scheme, rest, default) = match origin.trim() {
        o if o.len() >= 8 && o[..8].eq_ignore_ascii_case("https://") => ("https", &o[8..], ":443"),
        o if o.len() >= 7 && o[..7].eq_ignore_ascii_case("http://") => ("http", &o[7..], ":80"),
        _ => return None,
    };
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    if rest.is_empty() || rest.contains(['/', '?', '#', '@', ' ']) {
        return None;
    }
    let a = authority(rest);
    Some((scheme, a.strip_suffix(default).map(String::from).unwrap_or(a)))
}

fn loopback(host: &str) -> bool {
    let h = authority(host);
    let name = if let Some(rest) = h.strip_prefix('[') { rest.split(']').next().unwrap_or("") } else { h.rsplit_once(':').map_or(h.as_str(), |(n, _)| n) };
    name == "localhost" || name.ends_with(".localhost") || name == "::1" || name.parse::<std::net::Ipv4Addr>().is_ok_and(|ip| ip.is_loopback())
}

/// Whether a request's `Origin` is this server itself: scheme, host and port (RFC 6454).
///
/// - `[server] public_url`, when set, is the server's origin behind a proxy.
/// - Otherwise, and for direct access beside a proxy, it is the `Host` the request came for:
///   with either scheme on a loopback host, and with `https` on any other (plain `http` there
///   only when `session_cookie_secure = "never"` says the deployment runs without TLS).
///
/// Forwarding headers (`X-Forwarded-Host`, `Forwarded`) are not read: nothing says a proxy
/// set them, and a deployment behind a proxy that rewrites `Host` states its origin in
/// `public_url`.
pub fn same_origin(cfg: &Config, headers: &HeaderMap, origin: &str) -> bool {
    let Some((scheme, auth)) = origin_parts(origin) else { return false };
    if cfg.server.public_url.as_deref().and_then(origin_parts).is_some_and(|own| own == (scheme, auth.clone())) {
        return true;
    }
    let Some(host) = headers.get(header::HOST).and_then(|v| v.to_str().ok()) else { return false };
    let default = if scheme == "https" { ":443" } else { ":80" };
    let host_auth = authority(host);
    if host_auth.strip_suffix(default).unwrap_or(&host_auth) != auth {
        return false;
    }
    loopback(host) || scheme == "https" || cfg.server.session_cookie_secure == CookieSecure::Never
}

/// Whether the session cookie of this request is the `Secure` one (`[server]
/// session_cookie_secure`). `auto`: always when `public_url` is an `https` origin (whatever
/// `Host` a proxy sends upstream); otherwise always except for a request to a loopback host,
/// where browsers other than Chrome and Firefox do not send a `Secure` cookie over plain
/// HTTP. A request without a `Host` is treated as not loopback.
pub fn cookie_secure(cfg: &Config, headers: &HeaderMap) -> bool {
    match cfg.server.session_cookie_secure {
        CookieSecure::Always => true,
        CookieSecure::Never => false,
        CookieSecure::Auto => {
            cfg.server.public_url.as_deref().and_then(origin_parts).is_some_and(|(scheme, _)| scheme == "https")
                || !headers.get(header::HOST).and_then(|v| v.to_str().ok()).is_some_and(loopback)
        }
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

/// Why a request made with the session cookie is refused before it runs, if it is: it does
/// not come from the server's own origin, or it changes something without the session's CSRF
/// token. `None`: go on.
///
/// The origin is judged by `Origin` when the browser sends it, and by `Sec-Fetch-Site` when
/// the browser sends that: anything but `same-origin` is refused, so a page of a sibling host
/// (`same-site`) cannot make even a read with the cookie, and neither can a navigation.
pub fn guard(cfg: &Config, headers: &HeaderMap, method: &Method, secret: &str) -> Option<&'static str> {
    const FOREIGN: &str = "a session is used from the console's own origin only";
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) {
        if !same_origin(cfg, headers, origin) {
            return Some(FOREIGN);
        }
    }
    if headers.get("sec-fetch-site").is_some_and(|v| v.as_bytes() != b"same-origin") {
        return Some(FOREIGN);
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

/// What a scan of a console page found: what breaks the Content-Security-Policy's promise,
/// and the files the page loads.
#[derive(Debug, Default, PartialEq)]
pub struct PageScan {
    /// Inline script or style, in any form: a `<style>` element, a `style` or `on…` attribute
    /// (however it is spaced), a `javascript:` URL, a `<script>` without `src` or with a body.
    pub inline: Vec<String>,
    /// The `src` of each script and the `href` of each `<link>`.
    pub files: Vec<String>,
}

/// The attributes of a start tag as `(name, value)`, lower-case names, whatever the spacing
/// around `=` and the quoting.
fn attributes(tag: &str) -> Vec<(String, String)> {
    let inner = tag.trim_start_matches('<').trim_end_matches('>').trim_end_matches('/');
    let mut rest = inner.trim_start().split_once(char::is_whitespace).map_or("", |(_, r)| r);
    let mut out = vec![];
    loop {
        rest = rest.trim_start();
        if rest.is_empty() {
            return out;
        }
        let end = rest.find(|c: char| c == '=' || c.is_whitespace()).unwrap_or(rest.len());
        let name = rest[..end].to_ascii_lowercase();
        rest = rest[end..].trim_start();
        let mut value = String::new();
        if let Some(after) = rest.strip_prefix('=') {
            let after = after.trim_start();
            let (v, tail) = match after.chars().next() {
                Some(q @ ('"' | '\'')) => after[1..].split_once(q).unwrap_or((&after[1..], "")),
                _ => after.split_once(char::is_whitespace).unwrap_or((after, "")),
            };
            value = v.to_string();
            rest = tail;
        }
        if !name.is_empty() {
            out.push((name, value));
        }
    }
}

/// Scan a page for inline script and style, and list the files it loads. The same scan
/// checks the console's page in this crate's tests and, as served, in the governance suite.
pub fn scan_page(html: &str) -> PageScan {
    let mut scan = PageScan::default();
    let mut rest = html;
    while let Some(at) = rest.find('<') {
        let end = rest[at..].find('>').map_or(rest.len(), |e| at + e + 1);
        let tag = &rest[at..end];
        let lower = tag.to_ascii_lowercase();
        let after = &rest[end..];
        rest = after;
        if lower.starts_with("</") || lower.starts_with("<!") {
            continue;
        }
        let attrs = attributes(tag);
        let attr = |name: &str| attrs.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone());
        if lower.starts_with("<style") {
            scan.inline.push(format!("a style element: {tag}"));
        }
        for (name, value) in &attrs {
            if name == "style" || (name.len() > 2 && name.starts_with("on") && name.bytes().all(|b| b.is_ascii_lowercase())) {
                scan.inline.push(format!("an inline {name} attribute: {tag}"));
            }
            if value.trim_start().to_ascii_lowercase().starts_with("javascript:") {
                scan.inline.push(format!("a javascript: URL: {tag}"));
            }
        }
        if lower.starts_with("<script") {
            match attr("src") {
                Some(src) if after.trim_start().to_ascii_lowercase().starts_with("</script>") => scan.files.push(src),
                Some(_) => scan.inline.push(format!("a script with a body: {tag}")),
                None => scan.inline.push(format!("a script without src: {tag}")),
            }
        }
        if lower.starts_with("<link") {
            if let Some(href) = attr("href") {
                scan.files.push(href);
            }
        }
    }
    scan
}

/// Cross-origin requests (T3). A request without `Origin`, or from this server's own origin,
/// passes untouched. One from an origin on `[server] cors_origins` is answered with that
/// origin allowed, never `*` and never with credentials. Any other origin is refused before
/// anything runs, preflight or not.
pub(crate) async fn cors(State(st): State<AppState>, req: Request, next: Next) -> Response {
    let Some(origin) = req.headers().get(header::ORIGIN).and_then(|v| v.to_str().ok()).map(String::from) else {
        return next.run(req).await;
    };
    if same_origin(&st.engine.cfg, req.headers(), &origin) {
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
    /// none, and everything they load is a file this server serves.
    #[test]
    fn pages_have_no_inline_script_or_style_and_load_only_served_files() {
        let scan = scan_page(HTML);
        assert_eq!(scan.inline, Vec::<String>::new());
        assert_eq!(scan.files, ["/console.css", "/console.js"]);
        for f in &scan.files {
            assert!(ASSETS.iter().any(|(p, _, _)| p == f), "{f} is not served");
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

    /// The scan finds inline script and style however they are written.
    #[test]
    fn the_page_scan_finds_every_form_of_inline_script_and_style() {
        for (html, what) in [
            ("<p style=\"color: red\">x</p>", "style attribute"),
            ("<p style = \"color: red\">x</p>", "style attribute with spaces around the equals sign"),
            ("<p\n  STYLE='color: red'>x</p>", "style attribute in capitals on another line"),
            ("<p style=color:red>x</p>", "unquoted style attribute"),
            ("<style>p { color: red }</style>", "style element"),
            ("<button onclick=\"go()\">x</button>", "event handler"),
            ("<button onClick = go()>x</button>", "event handler with spaces"),
            ("<a href=\" JavaScript:go()\">x</a>", "javascript: URL"),
            ("<script>go()</script>", "script without src"),
            ("<script src=\"/console.js\">go()</script>", "script with a body"),
        ] {
            assert!(!scan_page(html).inline.is_empty(), "not found: {what}");
        }
        // And nothing where there is none: attribute values and names that only look alike.
        let clean =
            scan_page("<p class=\"style on\" data-style=\"x\" title=\"onclick=go()\">a style = b</p><script src=\"/a.js\"></script><link rel=\"stylesheet\" href=\"/a.css\">");
        assert_eq!((clean.inline, clean.files), (vec![], vec!["/a.js".to_string(), "/a.css".to_string()]));
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
        let cfg = Config::default();
        let secret = "mhs_secret";
        let token = memhouse_core::identity::csrf_token(secret);
        let own = [("host", "memhouse.example.com"), ("origin", "https://memhouse.example.com")];
        assert_eq!(guard(&cfg, &headers(&own), &Method::GET, secret), None);
        assert!(guard(&cfg, &headers(&own), &Method::POST, secret).unwrap().contains("csrf"));
        let mut with = own.to_vec();
        with.push((CSRF_HEADER, &token));
        assert_eq!(guard(&cfg, &headers(&with), &Method::POST, secret), None);
        assert_eq!(guard(&cfg, &headers(&with), &Method::DELETE, secret), None);
        // The token of another session is not this one's.
        let other = memhouse_core::identity::csrf_token("mhs_other");
        assert!(guard(&cfg, &headers(&[("host", "h"), (CSRF_HEADER, &other)]), &Method::POST, secret).is_some());
        // Another origin is refused even for a read and even with the token.
        let foreign = [("host", "memhouse.example.com"), ("origin", "https://evil.example"), (CSRF_HEADER, token.as_str())];
        assert!(guard(&cfg, &headers(&foreign), &Method::GET, secret).unwrap().contains("own origin"));
        assert!(guard(&cfg, &headers(&foreign), &Method::POST, secret).is_some());
        assert!(guard(&cfg, &headers(&[("host", "h"), ("origin", "null")]), &Method::GET, secret).is_some());
        // Fetch metadata: only the console's own fetches pass; a sibling host's page
        // (`same-site`), another site's and a navigation do not, also without `Origin`.
        for (site, passes) in [("same-origin", true), ("same-site", false), ("cross-site", false), ("none", false)] {
            assert_eq!(guard(&cfg, &headers(&[("host", "memhouse.example.com"), ("sec-fetch-site", site)]), &Method::GET, secret).is_none(), passes, "{site}");
        }
    }

    #[test]
    fn the_own_origin_is_scheme_host_and_port_and_forwarding_headers_are_not_trusted() {
        let cfg = Config::default();
        let h = |host: &str| headers(&[("host", host)]);
        // Scheme and port are part of an origin.
        assert!(same_origin(&cfg, &h("memhouse.example.com"), "https://memhouse.example.com"));
        assert!(same_origin(&cfg, &h("memhouse.example.com"), "https://MemHouse.example.com:443"));
        assert!(!same_origin(&cfg, &h("memhouse.example.com"), "http://memhouse.example.com"), "plain HTTP is another origin");
        assert!(!same_origin(&cfg, &h("memhouse.example.com"), "https://memhouse.example.com:8443"));
        assert!(!same_origin(&cfg, &h("memhouse.example.com"), "https://memhouse.example.com.evil.example"));
        // A loopback host has no TLS: either scheme, the port as written.
        assert!(same_origin(&cfg, &h("LocalHost:7077"), "http://localhost:7077"));
        assert!(!same_origin(&cfg, &h("localhost:7077"), "http://localhost:7078"));
        assert!(same_origin(&cfg, &h("localhost"), "http://localhost:80"));
        // Plain HTTP on another host only where the deployment says it runs without TLS.
        let mut plain = Config::default();
        plain.server.session_cookie_secure = CookieSecure::Never;
        assert!(same_origin(&plain, &h("10.0.0.5:7077"), "http://10.0.0.5:7077"));
        assert!(!same_origin(&cfg, &h("10.0.0.5:7077"), "http://10.0.0.5:7077"));
        // X-Forwarded-Host says nothing: a proxy that rewrites Host needs `public_url`.
        let proxied = headers(&[("host", "127.0.0.1:7077"), ("x-forwarded-host", "memhouse.example.com")]);
        assert!(!same_origin(&cfg, &proxied, "https://memhouse.example.com"));
        let mut public = Config::default();
        public.server.public_url = Some("https://memhouse.example.com".into());
        assert!(same_origin(&public, &proxied, "https://memhouse.example.com"));
        assert!(!same_origin(&public, &proxied, "http://memhouse.example.com"));
        assert!(!same_origin(&public, &proxied, "https://other.example.com"));
        // With an https public origin the cookie is the Secure one whatever Host the proxy sends,
        // and the plain cookie a page could have planted is not read.
        assert!(cookie_secure(&public, &proxied));
        assert!(!cookie_secure(&cfg, &h("localhost:7077")), "direct loopback HTTP keeps the plain cookie");
        let planted = headers(&[("host", "127.0.0.1:7077"), ("cookie", "memhouse_session=mhs_planted")]);
        assert_eq!(session_cookie(&public, &planted), None);
        // The setting is checked when the configuration is read.
        for bad in ["memhouse.example.com", "https://memhouse.example.com/console", "ftp://x", "https://*"] {
            let mut c = Config::default();
            c.server.public_url = Some(bad.into());
            assert!(c.check_ranges().is_err(), "{bad}");
        }
        assert!(public.check_ranges().is_ok());
        let mut short = Config::default();
        short.server.session_idle_secs = 30;
        assert!(short.check_ranges().unwrap_err().to_string().contains("session_idle_secs"));
    }
}
