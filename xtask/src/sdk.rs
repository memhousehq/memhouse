// SPDX-License-Identifier: Apache-2.0
//! The SDK generator (roadmap G18, INT-03): `cargo xtask sdk` reads `api/openapi.json` and writes
//! the low-level clients of the Python and TypeScript SDKs, one method per operation and one
//! type per schema. `cargo xtask sdk --check` (a step of `cargo xtask ci`) fails when the files
//! on disk are not what the specification gives, so the SDKs cannot fall behind the API.
//!
//! The output is deterministic: schemas and their properties are written in name order, paths in
//! path order, methods in a fixed order. A schema construct the generator cannot express becomes
//! a permissive type (`Any` in Python, `unknown` in TypeScript), never an error.

use serde_json::Value;
use std::collections::BTreeSet;
use std::path::Path;

const SPEC: &str = "api/openapi.json";
pub const PYTHON_OUT: &str = "sdk/python/src/memhouse/_generated.py";
pub const TYPESCRIPT_OUT: &str = "sdk/typescript/src/generated.ts";
const METHODS: [&str; 5] = ["get", "post", "put", "patch", "delete"];

/// Write the generated files, or with `check` compare them with what is on disk.
pub fn task(root: &Path, check: bool) -> Result<(), String> {
    let text = std::fs::read_to_string(root.join(SPEC)).map_err(|e| format!("{SPEC}: {e}"))?;
    let spec: Value = serde_json::from_str(&text).map_err(|e| format!("{SPEC}: {e}"))?;
    let (python, typescript) = generate(&spec)?;
    let mut stale = vec![];
    for (path, new) in [(PYTHON_OUT, python), (TYPESCRIPT_OUT, typescript)] {
        let file = root.join(path);
        if check {
            if std::fs::read_to_string(&file).ok().as_deref() != Some(new.as_str()) {
                stale.push(path);
            }
        } else {
            if let Some(dir) = file.parent() {
                std::fs::create_dir_all(dir).map_err(|e| format!("{path}: {e}"))?;
            }
            std::fs::write(&file, new).map_err(|e| format!("{path}: {e}"))?;
            eprintln!("wrote {path}");
        }
    }
    if stale.is_empty() {
        if check {
            eprintln!("generated SDK clients: up to date with {SPEC}");
        }
        Ok(())
    } else {
        Err(format!("{} differ(s) from what {SPEC} gives: run `cargo xtask sdk` and commit the result", stale.join(" and ")))
    }
}

#[derive(Clone, Copy, PartialEq)]
enum In {
    Path,
    Query,
    Header,
}

struct Param {
    /// The name on the wire: `include_inactive`, `Idempotency-Key`.
    wire: String,
    /// The argument's name in snake case, unique within the operation.
    name: String,
    place: In,
    required: bool,
    deprecated: bool,
    schema: Value,
    description: String,
}

enum Response {
    Json(Value),
    Text,
    /// No 200 body the generator can read: the method returns the parsed JSON, untyped.
    Unknown,
}

struct Op {
    id: String,
    method: String,
    path: String,
    doc: Vec<String>,
    /// `Deprecated: use ...; sunset: ...`, for a deprecated operation.
    deprecation: Option<String>,
    params: Vec<Param>,
    /// The JSON request body's schema, and whether the request needs one.
    body: Option<(Value, bool)>,
    response: Response,
}

/// The Python and the TypeScript source for a specification.
pub fn generate(spec: &Value) -> Result<(String, String), String> {
    let version = spec["info"]["version"].as_str().unwrap_or("unknown");
    let ops = operations(spec)?;
    let mut schemas: Vec<(&String, &Value)> = spec["components"]["schemas"].as_object().map(|m| m.iter().collect()).unwrap_or_default();
    schemas.sort_by(|a, b| a.0.cmp(b.0));
    Ok((python(version, &schemas, &ops), typescript(version, &schemas, &ops)))
}

fn operations(spec: &Value) -> Result<Vec<Op>, String> {
    let mut paths: Vec<(&String, &Value)> = spec["paths"].as_object().map(|m| m.iter().collect()).unwrap_or_default();
    paths.sort_by(|a, b| a.0.cmp(b.0));
    let mut ops = vec![];
    let mut seen = BTreeSet::new();
    for (path, item) in paths {
        for method in METHODS {
            let Some(o) = item.get(method).filter(|o| o.is_object()) else { continue };
            // An operation without an id still gets a method, named after its route.
            let id = o["operationId"].as_str().map(String::from).unwrap_or_else(|| format!("{method}_{}", snake(path)));
            if !seen.insert(id.clone()) {
                return Err(format!("{SPEC}: two operations are called {id}"));
            }
            let mut params: Vec<Param> = vec![];
            // Parameters of the path item apply to each of its operations.
            for p in item["parameters"].as_array().into_iter().flatten().chain(o["parameters"].as_array().into_iter().flatten()) {
                let p = resolve(spec, p);
                let (Some(wire), Some(place)) = (p["name"].as_str(), p["in"].as_str()) else { continue };
                let place = match place {
                    "path" => In::Path,
                    "query" => In::Query,
                    "header" => In::Header,
                    _ => continue, // cookies: the API has none
                };
                let short = if place == In::Header { wire.to_ascii_lowercase().trim_start_matches("x-memhouse-").to_string() } else { wire.to_string() };
                let mut name = snake(&short);
                // `body` and `options` are the generated methods' own argument names.
                while params.iter().any(|q| q.name == name) || name == "body" || name == "options" || name == "self" {
                    name.push_str(if place == In::Header { "_header" } else { "_" });
                }
                params.push(Param {
                    wire: wire.to_string(),
                    name,
                    place,
                    required: place == In::Path || p["required"] == true,
                    deprecated: p["deprecated"] == true,
                    schema: p["schema"].clone(),
                    description: p["description"].as_str().unwrap_or_default().to_string(),
                });
            }
            for name in path.split('{').skip(1).filter_map(|s| s.split_once('}').map(|(n, _)| n)) {
                if !params.iter().any(|p| p.place == In::Path && p.wire == name) {
                    return Err(format!("{SPEC}: {method} {path} does not declare its path parameter {name}"));
                }
            }
            let body = o.get("requestBody").map(|b| resolve(spec, b)).and_then(|b| b["content"]["application/json"].get("schema").map(|s| (s.clone(), b["required"] == true)));
            let ok = o["responses"].as_object().and_then(|r| r.iter().find(|(code, _)| code.starts_with('2')).map(|(_, v)| resolve(spec, v)));
            let response = match ok.map(|r| &r["content"]) {
                Some(c) if c.get("application/json").is_some() => Response::Json(c["application/json"]["schema"].clone()),
                Some(c) if c.as_object().is_some_and(|m| m.keys().any(|k| k.starts_with("text/"))) => Response::Text,
                _ => Response::Unknown,
            };
            let mut doc = vec![];
            if let Some(s) = o["summary"].as_str().filter(|s| !s.is_empty()) {
                doc.push(format!("{}.", s.trim_end_matches('.')));
                doc.push(String::new());
            }
            if let Some(d) = o["description"].as_str().filter(|d| !d.is_empty()) {
                doc.extend(d.lines().map(String::from));
                doc.push(String::new());
            }
            doc.push(format!("`{} {path}`. Stability: {}.", method.to_uppercase(), o["x-stability"].as_str().unwrap_or("not stated")));
            let deprecation = (o["deprecated"] == true).then(|| {
                let mut notes = vec![];
                if let Some(s) = o["x-successor"].as_str() {
                    notes.push(format!("use {s}"));
                }
                if let Some(s) = o["x-sunset"].as_str() {
                    notes.push(format!("sunset: {s}"));
                }
                notes.join("; ")
            });
            ops.push(Op { id, method: method.to_uppercase(), path: path.clone(), doc, deprecation, params, body, response });
        }
    }
    Ok(ops)
}

/// Follow a `#/components/...` reference one level; anything else is returned as it is.
fn resolve<'a>(spec: &'a Value, v: &'a Value) -> &'a Value {
    match v["$ref"].as_str().and_then(|r| r.strip_prefix("#/")) {
        Some(pointer) => spec.pointer(&format!("/{pointer}")).unwrap_or(v),
        None => v,
    }
}

/// `listMemories`, `Idempotency-Key`, `/v1/x/{id}` → `list_memories`, `idempotency_key`, `v1_x_id`.
fn snake(name: &str) -> String {
    let mut out = String::new();
    let mut previous_lower = false;
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            if c.is_ascii_uppercase() && previous_lower {
                out.push('_');
            }
            previous_lower = c.is_ascii_lowercase() || c.is_ascii_digit();
            out.push(c.to_ascii_lowercase());
        } else {
            if !out.is_empty() && !out.ends_with('_') {
                out.push('_');
            }
            previous_lower = false;
        }
    }
    let out = out.trim_end_matches('_').to_string();
    match out.chars().next() {
        None => "x".into(),
        Some(c) if c.is_ascii_digit() => format!("x{out}"),
        _ => out,
    }
}

/// `include_inactive` → `includeInactive`.
fn camel(snake: &str) -> String {
    let mut out = String::new();
    let mut upper = false;
    for c in snake.chars() {
        if c == '_' {
            upper = !out.is_empty();
        } else if upper {
            out.push(c.to_ascii_uppercase());
            upper = false;
        } else {
            out.push(c);
        }
    }
    out
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// The schema's name when it is a reference to a component schema.
fn reference(s: &Value) -> Option<&str> {
    s["$ref"].as_str().and_then(|r| r.strip_prefix("#/components/schemas/")).filter(|n| is_identifier(n))
}

/// The values of a schema that only allows listed constants (`const`, `enum`, or a `oneOf` /
/// `anyOf` of those), in the order the specification gives them.
fn literals(s: &Value) -> Option<Vec<&Value>> {
    if let Some(c) = s.get("const") {
        return Some(vec![c]);
    }
    if let Some(e) = s["enum"].as_array() {
        return Some(e.iter().collect());
    }
    let branches = s["oneOf"].as_array().or_else(|| s["anyOf"].as_array())?;
    let mut all = vec![];
    for b in branches {
        all.extend(literals(b)?);
    }
    (!all.is_empty()).then_some(all)
}

/// A constant as source text (the same in Python and TypeScript for strings and numbers).
fn literal(v: &Value, python: bool) -> Option<String> {
    match v {
        Value::String(_) | Value::Number(_) => Some(v.to_string()),
        Value::Bool(b) if python => Some(if *b { "True" } else { "False" }.into()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Null if python => Some("None".into()),
        Value::Null => Some("null".into()),
        _ => None,
    }
}

/// The `type` keyword as a list of names (`"string"` and `["string", "null"]` alike).
fn type_names(s: &Value) -> Vec<&str> {
    match &s["type"] {
        Value::String(t) => vec![t.as_str()],
        Value::Array(a) => a.iter().filter_map(Value::as_str).collect(),
        _ => vec![],
    }
}

// ---------------------------------------------------------------------------------------------
// Python

const PY_KEYWORDS: [&str; 35] = [
    "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
    "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
];

fn py_name(name: &str) -> String {
    if PY_KEYWORDS.contains(&name) {
        format!("{name}_")
    } else {
        name.to_string()
    }
}

/// A type expression. `quote` writes references to other models as strings, for places Python
/// evaluates at import (aliases and the functional `TypedDict` form).
fn py_type(s: &Value, quote: bool) -> String {
    if let Some(name) = reference(s) {
        return if quote { format!("\"{name}\"") } else { name.to_string() };
    }
    if let Some(values) = literals(s) {
        let written: Option<Vec<String>> = values.iter().map(|v| literal(v, true)).collect();
        return match written {
            Some(w) => format!("Literal[{}]", w.join(", ")),
            None => "Any".into(),
        };
    }
    if let Some(branches) = s["anyOf"].as_array().or_else(|| s["oneOf"].as_array()) {
        let null = |b: &&Value| b["type"] == "null";
        let mut others: Vec<String> = branches.iter().filter(|b| !null(b)).map(|b| py_type(b, quote)).collect();
        others.dedup();
        let inner = match others.len() {
            0 => return "None".into(),
            1 => others.remove(0),
            _ if others.iter().any(|t| t == "Any") => "Any".into(),
            _ => format!("Union[{}]", others.join(", ")),
        };
        return if branches.iter().any(|b| null(&b)) && inner != "Any" { format!("Optional[{inner}]") } else { inner };
    }
    let names = type_names(s);
    let one = |t: &str| -> String {
        match t {
            "string" => "str".into(),
            "integer" => "int".into(),
            "number" => "float".into(),
            "boolean" => "bool".into(),
            "null" => "None".into(),
            "array" => match s.get("items") {
                Some(items) if items.is_object() => format!("List[{}]", py_type(items, quote)),
                _ => "List[Any]".into(), // tuples (`prefixItems`) arrive as JSON arrays
            },
            "object" => match s.get("additionalProperties") {
                Some(extra) if extra.is_object() && s.get("properties").is_none() => format!("Dict[str, {}]", py_type(extra, quote)),
                _ => "Dict[str, Any]".into(),
            },
            _ => "Any".into(),
        }
    };
    let mut others: Vec<String> = names.iter().filter(|t| **t != "null").map(|t| one(t)).collect();
    others.dedup();
    let inner = match others.len() {
        0 if names.contains(&"null") => return "None".into(),
        0 => return "Any".into(), // no type: free-form JSON
        1 => others.remove(0),
        _ => format!("Union[{}]", others.join(", ")),
    };
    if names.contains(&"null") && inner != "Any" {
        format!("Optional[{inner}]")
    } else {
        inner
    }
}

fn py_comment(out: &mut String, indent: &str, text: &str) {
    for line in text.lines() {
        out.push_str(format!("{indent}# {line}").trim_end());
        out.push('\n');
    }
}

fn py_docstring(out: &mut String, indent: &str, lines: &[String]) {
    let clean = |l: &str| l.replace('\\', "\\\\").replace("\"\"\"", "\\\"\\\"\\\"");
    let lines: Vec<String> = lines.iter().map(|l| clean(l)).collect();
    let last = lines.iter().rposition(|l| !l.trim().is_empty()).map(|i| i + 1).unwrap_or(0);
    match &lines[..last] {
        [] => {}
        // A closing quote right after a quote would end the string early.
        [one] if !one.ends_with('"') => out.push_str(&format!("{indent}\"\"\"{one}\"\"\"\n")),
        many => {
            out.push_str(&format!("{indent}\"\"\"{}\n", many[0]));
            for l in &many[1..] {
                out.push_str(format!("{indent}{l}").trim_end());
                out.push('\n');
            }
            out.push_str(&format!("{indent}\"\"\"\n"));
        }
    }
}

fn python(version: &str, schemas: &[(&String, &Value)], ops: &[Op]) -> String {
    let mut out = String::new();
    out.push_str("# SPDX-License-Identifier: Apache-2.0\n");
    out.push_str(&format!("# Generated by `cargo xtask sdk` from api/openapi.json (MemHouse API {version}). Do not edit:\n"));
    out.push_str("# change the API, then run `cargo xtask sdk` again. `cargo xtask sdk --check` fails on a difference.\n");
    out.push_str("\"\"\"The MemHouse API as types and one method per operation (generated).\"\"\"\n\n");
    out.push_str("from __future__ import annotations\n\n");
    out.push_str("from typing import Any, Dict, List, Literal, Optional, TypedDict, Union\n");
    out.push_str("from urllib.parse import quote as _quote\n\n");
    out.push_str(&format!("API_VERSION = \"{version}\"\n"));
    out.push_str("\"\"\"The version of the API specification this client was generated from.\"\"\"\n\n");
    out.push_str("# `Union` is imported for schemas that need it; not every specification has one.\n");
    out.push_str("__all__ = [\"API_VERSION\", \"GeneratedClient\", \"Union\"]\n");

    for (name, schema) in schemas {
        if !is_identifier(name) {
            continue; // cannot be named; references to it are typed `Any`
        }
        out.push_str("\n\n");
        let description = schema["description"].as_str().unwrap_or_default();
        let properties = schema["properties"].as_object().filter(|_| literals(schema).is_none() && type_names(schema).contains(&"object"));
        let Some(properties) = properties else {
            // An enumeration, or anything that is not an object with named fields: an alias.
            py_comment(&mut out, "", description);
            out.push_str(&format!("{name} = {}\n", py_type(schema, true)));
            continue;
        };
        let mut fields: Vec<(&String, &Value)> = properties.iter().collect();
        fields.sort_by(|a, b| a.0.cmp(b.0));
        let required: BTreeSet<&str> = schema["required"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        let (needed, optional): (Vec<_>, Vec<_>) = fields.iter().partition(|(n, _)| required.contains(n.as_str()));
        // The class form cannot spell a field named like a keyword (`from`): the functional
        // form takes any string.
        let functional = fields.iter().any(|(n, _)| !is_identifier(n) || PY_KEYWORDS.contains(&n.as_str()));
        let doc: Vec<String> = description.lines().map(String::from).collect();
        let class = |out: &mut String, class_name: &str, base: &str, total: bool, fields: &[&(&String, &Value)], doc: &[String]| {
            let total = if total { "" } else { ", total=False" };
            if functional {
                for (n, s) in fields {
                    if let Some(d) = s["description"].as_str() {
                        py_comment(out, "", &format!("{class_name}[{}]: {d}", Value::String(n.to_string())));
                    }
                }
                let items: Vec<String> = fields.iter().map(|(n, s)| format!("{}: {}", Value::String(n.to_string()), py_type(s, true))).collect();
                if base == "TypedDict" {
                    out.push_str(&format!("{class_name} = TypedDict(\"{class_name}\", {{{}}}{total})\n", items.join(", ")));
                } else {
                    // The functional form has no base class: inherit through a class statement.
                    out.push_str(&format!("_{class_name}Optional = TypedDict(\"_{class_name}Optional\", {{{}}}{total})\n\n\n", items.join(", ")));
                    out.push_str(&format!("class {class_name}({base}, _{class_name}Optional):\n"));
                    py_docstring(out, "    ", doc);
                    if doc.is_empty() {
                        out.push_str("    pass\n");
                    }
                }
                return;
            }
            out.push_str(&format!("class {class_name}({base}{total}):\n"));
            py_docstring(out, "    ", doc);
            if fields.is_empty() && doc.is_empty() {
                out.push_str("    pass\n");
            }
            for (i, (n, s)) in fields.iter().enumerate() {
                if let Some(d) = s["description"].as_str() {
                    if i > 0 || !doc.is_empty() {
                        out.push('\n');
                    }
                    py_comment(out, "    ", d);
                }
                out.push_str(&format!("    {n}: {}\n", py_type(s, false)));
            }
        };
        if needed.is_empty() || optional.is_empty() {
            if functional && !doc.is_empty() {
                py_comment(&mut out, "", description);
            }
            class(&mut out, name, "TypedDict", optional.is_empty(), if needed.is_empty() { &optional } else { &needed }, &doc);
        } else {
            // Python 3.9 has no `NotRequired`: the required fields are a base class.
            let base = format!("_{name}Required");
            class(&mut out, &base, "TypedDict", true, &needed, &[]);
            out.push_str("\n\n");
            class(&mut out, name, &base, false, &optional, &doc);
        }
    }

    out.push_str("\n\ndef _segment(value: Any) -> str:\n    \"\"\"A path parameter, percent-encoded.\"\"\"\n    return _quote(str(value), safe=\"\")\n");
    out.push_str("\n\nclass GeneratedClient:\n");
    out.push_str("    \"\"\"One method per operation of the API. A subclass provides `_call`, which sends the request.\"\"\"\n\n");
    out.push_str("    def _call(\n        self,\n        method: str,\n        path: str,\n        query: Optional[Dict[str, Any]] = None,\n        body: Any = None,\n        headers: Optional[Dict[str, Optional[str]]] = None,\n        text: bool = False,\n    ) -> Any:\n");
    out.push_str("        raise NotImplementedError\n");
    for op in ops {
        let mut args = vec!["self".to_string()];
        let positional = |p: &&Param| p.place == In::Path || p.required;
        for p in op.params.iter().filter(positional) {
            args.push(format!("{}: {}", py_name(&p.name), py_type(&p.schema, false)));
        }
        if let Some((schema, required)) = &op.body {
            let t = py_type(schema, false);
            args.push(if *required { format!("body: {t}") } else { format!("body: Optional[{t}] = None") });
        }
        let named: Vec<&Param> = op.params.iter().filter(|p| !positional(p)).collect();
        if !named.is_empty() {
            args.push("*".into());
            for p in &named {
                let t = py_type(&p.schema, false);
                args.push(format!("{}: {} = None", py_name(&p.name), if t.starts_with("Optional[") || t == "Any" { t } else { format!("Optional[{t}]") }));
            }
        }
        let returns = match &op.response {
            Response::Json(s) => py_type(s, false),
            Response::Text => "str".into(),
            Response::Unknown => "Any".into(),
        };
        out.push_str(&format!("\n    def {}({}) -> {returns}:\n", py_name(&snake(&op.id)), args.join(", ")));
        let mut doc = op.doc.clone();
        if let Some(d) = &op.deprecation {
            doc.push(format!("Deprecated{}{d}.", if d.is_empty() { "" } else { ": " }));
        }
        let described: Vec<&Param> = op.params.iter().filter(|p| !p.description.is_empty() || p.deprecated).collect();
        if !described.is_empty() {
            doc.push(String::new());
            for p in described {
                let text = format!("{}{}", if p.deprecated { "(deprecated) " } else { "" }, p.description.replace('\n', " "));
                doc.push(format!("- `{}`: {}", py_name(&p.name), text.trim()));
            }
        }
        py_docstring(&mut out, "        ", &doc);
        let path = py_path(op);
        let mut call = vec![format!("\"{}\"", op.method), path];
        let pairs = |place: In| -> Vec<String> { op.params.iter().filter(|p| p.place == place).map(|p| format!("\"{}\": {}", p.wire, py_name(&p.name))).collect() };
        if !pairs(In::Query).is_empty() {
            call.push(format!("query={{{}}}", pairs(In::Query).join(", ")));
        }
        if op.body.is_some() {
            call.push("body=body".into());
        }
        if !pairs(In::Header).is_empty() {
            call.push(format!("headers={{{}}}", pairs(In::Header).join(", ")));
        }
        if matches!(op.response, Response::Text) {
            call.push("text=True".into());
        }
        out.push_str(&format!("        return self._call({})\n", call.join(", ")));
    }
    out
}

/// `"/v1/memories/" + _segment(id)`.
fn py_path(op: &Op) -> String {
    let mut parts = vec![];
    let mut rest = op.path.as_str();
    while let Some((before, after)) = rest.split_once('{') {
        let (name, tail) = after.split_once('}').unwrap_or((after, ""));
        if !before.is_empty() {
            parts.push(format!("\"{before}\""));
        }
        let arg = op.params.iter().find(|p| p.place == In::Path && p.wire == name).map(|p| py_name(&p.name)).unwrap_or_else(|| py_name(&snake(name)));
        parts.push(format!("_segment({arg})"));
        rest = tail;
    }
    if !rest.is_empty() || parts.is_empty() {
        parts.push(format!("\"{rest}\""));
    }
    parts.join(" + ")
}

// ---------------------------------------------------------------------------------------------
// TypeScript

fn ts_key(name: &str) -> String {
    if is_identifier(name) {
        name.to_string()
    } else {
        Value::String(name.to_string()).to_string()
    }
}

fn ts_type(s: &Value) -> String {
    if let Some(name) = reference(s) {
        return name.to_string();
    }
    if let Some(values) = literals(s) {
        let written: Option<Vec<String>> = values.iter().map(|v| literal(v, false)).collect();
        return written.map(|w| w.join(" | ")).unwrap_or_else(|| "unknown".into());
    }
    let union = |mut parts: Vec<String>| -> String {
        let mut seen = BTreeSet::new();
        parts.retain(|p| seen.insert(p.clone()));
        if parts.iter().any(|p| p == "unknown") {
            "unknown".into()
        } else {
            parts.join(" | ")
        }
    };
    // A union inside an array or a record needs brackets.
    let inner = |s: &Value| -> String {
        let t = ts_type(s);
        if t.contains(" | ") {
            format!("({t})")
        } else {
            t
        }
    };
    if let Some(branches) = s["anyOf"].as_array().or_else(|| s["oneOf"].as_array()) {
        return union(branches.iter().map(ts_type).collect());
    }
    let names = type_names(s);
    if names.is_empty() {
        return "unknown".into(); // no type: free-form JSON
    }
    union(
        names
            .iter()
            .map(|t| match *t {
                "string" => "string".into(),
                "integer" | "number" => "number".into(),
                "boolean" => "boolean".into(),
                "null" => "null".into(),
                "array" => match (s.get("items"), s["prefixItems"].as_array()) {
                    (Some(items), _) if items.is_object() => format!("{}[]", inner(items)),
                    (_, Some(tuple)) => format!("[{}]", tuple.iter().map(ts_type).collect::<Vec<_>>().join(", ")),
                    _ => "unknown[]".into(),
                },
                "object" => match (s["properties"].as_object(), s.get("additionalProperties")) {
                    (Some(properties), _) => {
                        let required: BTreeSet<&str> = s["required"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
                        let mut fields: Vec<(&String, &Value)> = properties.iter().collect();
                        fields.sort_by(|a, b| a.0.cmp(b.0));
                        let fields: Vec<String> =
                            fields.iter().map(|(n, p)| format!("{}{}: {}", ts_key(n), if required.contains(n.as_str()) { "" } else { "?" }, ts_type(p))).collect();
                        format!("{{ {} }}", fields.join("; "))
                    }
                    (None, Some(extra)) if extra.is_object() => format!("Record<string, {}>", ts_type(extra)),
                    _ => "Record<string, unknown>".into(),
                },
                _ => "unknown".into(),
            })
            .collect(),
    )
}

fn ts_doc(out: &mut String, indent: &str, lines: &[String]) {
    let last = lines.iter().rposition(|l| !l.trim().is_empty()).map(|i| i + 1).unwrap_or(0);
    if last == 0 {
        return;
    }
    out.push_str(&format!("{indent}/**\n"));
    for l in &lines[..last] {
        out.push_str(format!("{indent} * {}", l.replace("*/", "*\\/")).trim_end());
        out.push('\n');
    }
    out.push_str(&format!("{indent} */\n"));
}

fn typescript(version: &str, schemas: &[(&String, &Value)], ops: &[Op]) -> String {
    let mut out = String::new();
    out.push_str("// SPDX-License-Identifier: Apache-2.0\n");
    out.push_str(&format!("// Generated by `cargo xtask sdk` from api/openapi.json (MemHouse API {version}). Do not edit:\n"));
    out.push_str("// change the API, then run `cargo xtask sdk` again. `cargo xtask sdk --check` fails on a difference.\n\n");
    out.push_str("/** The version of the API specification this client was generated from. */\n");
    out.push_str(&format!("export const API_VERSION = \"{version}\";\n"));
    for (name, schema) in schemas {
        if !is_identifier(name) {
            continue;
        }
        out.push('\n');
        let doc: Vec<String> = schema["description"].as_str().unwrap_or_default().lines().map(String::from).collect();
        ts_doc(&mut out, "", &doc);
        let properties = schema["properties"].as_object().filter(|_| literals(schema).is_none() && type_names(schema).contains(&"object"));
        let Some(properties) = properties else {
            out.push_str(&format!("export type {name} = {};\n", ts_type(schema)));
            continue;
        };
        let required: BTreeSet<&str> = schema["required"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        let mut fields: Vec<(&String, &Value)> = properties.iter().collect();
        fields.sort_by(|a, b| a.0.cmp(b.0));
        out.push_str(&format!("export interface {name} {{\n"));
        for (n, s) in fields {
            let doc: Vec<String> = s["description"].as_str().unwrap_or_default().lines().map(String::from).collect();
            ts_doc(&mut out, "  ", &doc);
            out.push_str(&format!("  {}{}: {};\n", ts_key(n), if required.contains(n.as_str()) { "" } else { "?" }, ts_type(s)));
        }
        out.push_str("}\n");
    }

    out.push_str("\n/** What a generated method hands to the transport. */\n");
    out.push_str("export interface CallOptions {\n  query?: Record<string, string | number | boolean | null | undefined>;\n  body?: unknown;\n  headers?: Record<string, string | null | undefined>;\n  /** The response is text, not JSON. */\n  text?: boolean;\n}\n");
    out.push_str("\n/** One method per operation of the API. A subclass provides `call`, which sends the request. */\n");
    out.push_str("export abstract class GeneratedClient {\n");
    out.push_str("  protected abstract call<T>(method: string, path: string, options?: CallOptions): Promise<T>;\n");
    for op in ops {
        let positional = |p: &&Param| p.place == In::Path || p.required;
        let mut args: Vec<String> = op.params.iter().filter(positional).map(|p| format!("{}: {}", camel(&p.name), ts_type(&p.schema))).collect();
        if let Some((schema, required)) = &op.body {
            let t = ts_type(schema);
            args.push(if *required { format!("body: {t}") } else { format!("body: {t} | undefined") });
        }
        let named: Vec<&Param> = op.params.iter().filter(|p| !positional(p)).collect();
        if !named.is_empty() {
            let fields: Vec<String> = named.iter().map(|p| format!("{}?: {}", camel(&p.name), ts_type(&p.schema))).collect();
            args.push(format!("options: {{ {} }} = {{}}", fields.join("; ")));
        }
        let returns = match &op.response {
            Response::Json(s) => ts_type(s),
            Response::Text => "string".into(),
            Response::Unknown => "unknown".into(),
        };
        let mut doc = op.doc.clone();
        let described: Vec<&Param> = op.params.iter().filter(|p| !p.description.is_empty() || p.deprecated).collect();
        if !described.is_empty() {
            doc.push(String::new());
            for p in described {
                let text = format!("{}{}", if p.deprecated { "(deprecated) " } else { "" }, p.description.replace('\n', " "));
                let name = if positional(&p) { camel(&p.name) } else { format!("options.{}", camel(&p.name)) };
                doc.push(format!("- `{name}`: {}", text.trim()));
            }
        }
        // `@deprecated` is what editors and the compiler read. A block tag comes last: the text
        // after it would belong to it.
        if let Some(d) = &op.deprecation {
            doc.push(String::new());
            doc.push(format!("@deprecated {d}").trim_end().to_string());
        }
        out.push('\n');
        ts_doc(&mut out, "  ", &doc);
        out.push_str(&format!("  {}({}): Promise<{returns}> {{\n", camel(&snake(&op.id)), args.join(", ")));
        let mut options = vec![];
        let pairs = |place: In| -> Vec<String> {
            op.params.iter().filter(|p| p.place == place).map(|p| format!("{}: {}{}", ts_key(&p.wire), if positional(&p) { "" } else { "options." }, camel(&p.name))).collect()
        };
        if !pairs(In::Query).is_empty() {
            options.push(format!("query: {{ {} }}", pairs(In::Query).join(", ")));
        }
        if op.body.is_some() {
            options.push("body".into());
        }
        if !pairs(In::Header).is_empty() {
            options.push(format!("headers: {{ {} }}", pairs(In::Header).join(", ")));
        }
        if matches!(op.response, Response::Text) {
            options.push("text: true".into());
        }
        let options = if options.is_empty() { String::new() } else { format!(", {{ {} }}", options.join(", ")) };
        out.push_str(&format!("    return this.call(\"{}\", {}{options});\n  }}\n", op.method, ts_path(op)));
    }
    out.push_str("}\n");
    out
}

/// `` `/v1/memories/${encodeURIComponent(id)}` ``.
fn ts_path(op: &Op) -> String {
    if !op.path.contains('{') {
        return format!("\"{}\"", op.path);
    }
    let mut out = String::from("`");
    let mut rest = op.path.as_str();
    while let Some((before, after)) = rest.split_once('{') {
        let (name, tail) = after.split_once('}').unwrap_or((after, ""));
        let arg = op.params.iter().find(|p| p.place == In::Path && p.wire == name).map(|p| camel(&p.name)).unwrap_or_else(|| camel(&snake(name)));
        out.push_str(&format!("{before}${{encodeURIComponent(String({arg}))}}"));
        rest = tail;
    }
    out.push_str(rest);
    out.push('`');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spec() -> Value {
        json!({
            "info": { "version": "9.9.9" },
            "paths": {
                "/v1/things/{id}": {
                    "get": {
                        "operationId": "getThing", "summary": "Read a thing", "x-stability": "stable",
                        "parameters": [
                            { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } },
                            { "name": "include_old", "in": "query", "description": "Also old ones.", "schema": { "type": "boolean" } },
                            { "$ref": "#/components/parameters/User" }
                        ],
                        "responses": { "200": { "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Thing" } } } } }
                    },
                    "delete": {
                        "operationId": "dropThing", "deprecated": true, "x-successor": "POST /v1/forget", "x-sunset": "2027-01-01", "x-stability": "deprecated",
                        "parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }],
                        "responses": { "200": { "content": { "text/plain": { "schema": { "type": "string" } } } } }
                    }
                },
                "/v1/things": {
                    "post": {
                        "operationId": "putThing",
                        "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Thing" } } } },
                        "responses": { "200": { "content": { "application/json": { "schema": { "type": "array", "items": { "$ref": "#/components/schemas/Thing" } } } } } }
                    }
                }
            },
            "components": {
                "parameters": { "User": { "name": "x-memhouse-user", "in": "header", "schema": { "type": "string" } } },
                "schemas": {
                    "Thing": {
                        "type": "object", "description": "A thing.", "required": ["name"],
                        "properties": {
                            "name": { "type": "string" },
                            "kind": { "anyOf": [{ "$ref": "#/components/schemas/Kind" }, { "type": "null" }] },
                            "size": { "type": ["integer", "null"], "description": "In metres." },
                            "pair": { "type": "array", "prefixItems": [{ "type": "string" }, { "type": "integer" }] },
                            "anything": {},
                            "odd": { "not": { "type": "string" } }
                        }
                    },
                    "Kind": { "oneOf": [{ "const": "a", "type": "string" }, { "enum": ["b"], "type": "string" }] },
                    "Move": { "type": "object", "properties": { "from": { "type": "string" }, "to": { "type": "string" } }, "required": ["from"] }
                }
            }
        })
    }

    #[test]
    fn python_has_a_method_per_operation_and_a_type_per_schema() {
        let (py, _) = generate(&spec()).unwrap();
        assert!(py.starts_with("# SPDX-License-Identifier: Apache-2.0\n# Generated by `cargo xtask sdk`"), "{py}");
        assert!(py.contains("Kind = Literal[\"a\", \"b\"]"), "{py}");
        assert!(py.contains("class _ThingRequired(TypedDict):\n    name: str\n"), "{py}");
        assert!(py.contains("class Thing(_ThingRequired, total=False):\n    \"\"\"A thing.\"\"\"\n    anything: Any\n    kind: Optional[Kind]\n    odd: Any\n    pair: List[Any]\n\n    # In metres.\n    size: Optional[int]\n"), "{py}");
        // A field named like a keyword needs the functional form.
        assert!(py.contains("_MoveRequired = TypedDict(\"_MoveRequired\", {\"from\": str})"), "{py}");
        assert!(py.contains("class Move(_MoveRequired, _MoveOptional):"), "{py}");
        assert!(py.contains("def get_thing(self, id: str, *, include_old: Optional[bool] = None, user: Optional[str] = None) -> Thing:"), "{py}");
        assert!(py.contains("return self._call(\"GET\", \"/v1/things/\" + _segment(id), query={\"include_old\": include_old}, headers={\"x-memhouse-user\": user})"), "{py}");
        assert!(py.contains("def put_thing(self, body: Thing) -> List[Thing]:"), "{py}");
        assert!(py.contains("Deprecated: use POST /v1/forget; sunset: 2027-01-01."), "{py}");
        assert!(py.contains("def drop_thing(self, id: str) -> str:") && py.contains("text=True"), "{py}");
    }

    #[test]
    fn typescript_has_a_method_per_operation_and_a_type_per_schema() {
        let (_, ts) = generate(&spec()).unwrap();
        assert!(ts.starts_with("// SPDX-License-Identifier: Apache-2.0\n// Generated by `cargo xtask sdk`"), "{ts}");
        assert!(ts.contains("export type Kind = \"a\" | \"b\";"), "{ts}");
        assert!(ts.contains("  anything?: unknown;\n  kind?: Kind | null;\n  name: string;\n  odd?: unknown;\n  pair?: [string, number];\n"), "{ts}");
        assert!(ts.contains("  size?: number | null;"), "{ts}");
        assert!(ts.contains("getThing(id: string, options: { includeOld?: boolean; user?: string } = {}): Promise<Thing> {"), "{ts}");
        assert!(ts.contains("return this.call(\"GET\", `/v1/things/${encodeURIComponent(String(id))}`, { query: { include_old: options.includeOld }, headers: { \"x-memhouse-user\": options.user } });"), "{ts}");
        assert!(ts.contains("putThing(body: Thing): Promise<Thing[]> {"), "{ts}");
        assert!(ts.contains("   * @deprecated use POST /v1/forget; sunset: 2027-01-01\n   */\n  dropThing(id: string): Promise<string> {"), "{ts}");
    }

    #[test]
    fn the_output_is_the_same_every_time_and_odd_specifications_do_not_crash() {
        assert_eq!(generate(&spec()).unwrap(), generate(&spec()).unwrap());
        // Nothing the generator expects is there: still two files, with no operations.
        let (py, ts) = generate(&json!({ "paths": { "/x": { "get": {} } }, "components": { "schemas": { "Odd": 3, "not a name": {} } } })).unwrap();
        assert!(py.contains("def get_x(self) -> Any:") && py.contains("Odd = Any"), "{py}");
        assert!(ts.contains("getX(): Promise<unknown> {") && ts.contains("export type Odd = unknown;"), "{ts}");
        // A path parameter the operation does not declare is a mistake in the specification.
        let broken = json!({ "paths": { "/x/{id}": { "get": { "operationId": "x" } } } });
        assert!(generate(&broken).unwrap_err().contains("does not declare its path parameter id"));
    }

    #[test]
    fn names_are_converted() {
        assert_eq!(snake("listMemoriesLegacy"), "list_memories_legacy");
        assert_eq!(snake("Idempotency-Key"), "idempotency_key");
        assert_eq!(camel("include_inactive"), "includeInactive");
        assert_eq!(py_name("from"), "from_");
    }
}
