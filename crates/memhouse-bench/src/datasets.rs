//! Public long-term memory benchmarks, loaded into one shape: a conversation (haystack of dated
//! sessions) plus questions with ground-truth evidence.

use anyhow::Context;
use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use serde::de::{DeserializeSeed, SeqAccess, Visitor};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Turn {
    pub role: String,
    pub content: String,
    pub ref_id: String,
    pub evidence: bool,
}

#[derive(Debug, Clone)]
pub struct Session {
    pub id: String,
    pub date: Option<DateTime<Utc>>,
    pub turns: Vec<Turn>,
}

#[derive(Debug, Clone)]
pub struct Question {
    pub id: String,
    pub qtype: String,
    pub question: String,
    pub answer: String,
    pub date: Option<DateTime<Utc>>,
    pub evidence_sessions: Vec<String>,
    pub evidence_turns: Vec<String>,
    /// The correct behaviour is to say the information is not available.
    pub abstention: bool,
}

#[derive(Debug, Clone)]
pub struct Item {
    pub conv_id: String,
    pub sessions: Vec<Session>,
    pub questions: Vec<Question>,
    /// Multi-party chat (no user/assistant roles): index each message on its own.
    pub per_message: bool,
}

pub struct DatasetInfo {
    pub name: &'static str,
    pub title: &'static str,
    pub url: &'static str,
    pub file: &'static str,
    pub size: &'static str,
}

pub const DATASETS: &[DatasetInfo] = &[
    DatasetInfo {
        name: "longmemeval-s",
        title: "LongMemEval_S (Wu et al., ICLR 2025): 500 questions, ~50 sessions / ~115k tokens of history each",
        url: "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_s_cleaned.json",
        file: "longmemeval_s_cleaned.json",
        size: "277 MB",
    },
    DatasetInfo {
        name: "longmemeval-m",
        title: "LongMemEval_M: 500 questions, ~500 sessions / ~1.5M tokens of history each",
        url: "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_m_cleaned.json",
        file: "longmemeval_m_cleaned.json",
        size: "2.7 GB",
    },
    DatasetInfo {
        name: "longmemeval-oracle",
        title: "LongMemEval oracle: evidence sessions only (upper bound for answering)",
        url: "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_oracle.json",
        file: "longmemeval_oracle.json",
        size: "15 MB",
    },
    DatasetInfo {
        name: "locomo",
        title: "LoCoMo (Maharana et al., ACL 2024): 10 long conversations, 1,986 questions (1,540 without adversarial)",
        url: "https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json",
        file: "locomo10.json",
        size: "2.8 MB",
    },
];

pub fn info(name: &str) -> anyhow::Result<&'static DatasetInfo> {
    DATASETS.iter().find(|d| d.name == name).ok_or_else(|| {
        anyhow::anyhow!("unknown dataset '{name}'. Available: {}", DATASETS.iter().map(|d| d.name).collect::<Vec<_>>().join(", "))
    })
}

pub fn data_dir() -> PathBuf {
    std::env::var("MEMHOUSE_BENCH_DATA").map(PathBuf::from).unwrap_or_else(|_| memhouse_core::config::home_dir().join("bench-data"))
}

pub fn path_for(name: &str) -> anyhow::Result<PathBuf> {
    Ok(data_dir().join(info(name)?.file))
}

pub async fn download(name: &str, force: bool) -> anyhow::Result<PathBuf> {
    use futures::StreamExt;
    use std::io::Write;
    let d = info(name)?;
    let path = data_dir().join(d.file);
    if path.exists() && !force {
        eprintln!("{} already downloaded: {}", d.name, path.display());
        return Ok(path);
    }
    std::fs::create_dir_all(data_dir())?;
    eprintln!("Downloading {} ({}) from {}", d.name, d.size, d.url);
    let resp = reqwest::Client::new().get(d.url).send().await?.error_for_status()?;
    let total = resp.content_length();
    let tmp = path.with_extension("part");
    let mut f = std::io::BufWriter::new(std::fs::File::create(&tmp)?);
    let mut got: u64 = 0;
    let mut last = 0u64;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        f.write_all(&chunk)?;
        got += chunk.len() as u64;
        if got - last > 8 << 20 {
            last = got;
            match total {
                Some(t) => eprint!("\r  {:.0} / {:.0} MB", got as f64 / 1e6, t as f64 / 1e6),
                None => eprint!("\r  {:.0} MB", got as f64 / 1e6),
            }
        }
    }
    f.flush()?;
    drop(f);
    std::fs::rename(&tmp, &path)?;
    eprintln!("\r  saved {} ({:.1} MB)", path.display(), got as f64 / 1e6);
    Ok(path)
}

pub fn parse_lme_date(s: &str) -> Option<DateTime<Utc>> {
    // "2023/05/20 (Sat) 02:21"
    let cleaned: String = {
        let mut out = String::new();
        let mut skip = false;
        for c in s.chars() {
            match c {
                '(' => skip = true,
                ')' => skip = false,
                _ if !skip => out.push(c),
                _ => {}
            }
        }
        out.split_whitespace().collect::<Vec<_>>().join(" ")
    };
    NaiveDateTime::parse_from_str(&cleaned, "%Y/%m/%d %H:%M")
        .ok()
        .or_else(|| NaiveDate::parse_from_str(&cleaned, "%Y/%m/%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)))
        .map(|d| d.and_utc())
}

pub fn parse_locomo_date(s: &str) -> Option<DateTime<Utc>> {
    // "1:56 pm on 8 May, 2023"
    let s = s.trim().to_ascii_lowercase();
    let (time, date) = s.split_once(" on ")?;
    let date = NaiveDate::parse_from_str(&date.replace(',', ""), "%d %B %Y").ok()?;
    let (hm, ampm) = time.split_once(' ').unwrap_or((time, "am"));
    let (h, m) = hm.split_once(':')?;
    let mut h: u32 = h.trim().parse().ok()?;
    let m: u32 = m.trim().parse().ok()?;
    if ampm.starts_with('p') && h < 12 {
        h += 12;
    }
    if ampm.starts_with('a') && h == 12 {
        h = 0;
    }
    date.and_hms_opt(h, m, 0).map(|d| d.and_utc())
}

#[derive(Deserialize)]
struct LmeTurn {
    role: String,
    content: String,
    #[serde(default)]
    has_answer: Option<bool>,
}

#[derive(Deserialize)]
struct LmeItem {
    question_id: String,
    question_type: String,
    question: String,
    answer: serde_json::Value,
    #[serde(default)]
    question_date: Option<String>,
    haystack_session_ids: Vec<String>,
    haystack_dates: Vec<String>,
    haystack_sessions: Vec<Vec<LmeTurn>>,
    #[serde(default)]
    answer_session_ids: Vec<String>,
}

fn json_to_string(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn lme_to_item(it: LmeItem) -> Item {
    let mut evidence_turns = vec![];
    let sessions: Vec<Session> = it
        .haystack_sessions
        .into_iter()
        .zip(it.haystack_session_ids.iter())
        .zip(it.haystack_dates.iter())
        .map(|((turns, sid), date)| Session {
            id: sid.clone(),
            date: parse_lme_date(date),
            turns: turns
                .into_iter()
                .enumerate()
                .map(|(i, t)| {
                    let ref_id = format!("{sid}#{i}");
                    let ev = t.has_answer.unwrap_or(false);
                    if ev {
                        evidence_turns.push(ref_id.clone());
                    }
                    Turn { role: t.role, content: t.content, ref_id, evidence: ev }
                })
                .collect(),
        })
        .collect();
    let abstention = it.question_id.ends_with("_abs");
    Item {
        conv_id: it.question_id.clone(),
        sessions,
        questions: vec![Question {
            id: it.question_id,
            qtype: it.question_type,
            question: it.question,
            answer: json_to_string(&it.answer),
            date: it.question_date.as_deref().and_then(parse_lme_date),
            evidence_sessions: it.answer_session_ids,
            evidence_turns,
            abstention,
        }],
        per_message: false,
    }
}

/// Stream the top-level JSON array one element at a time so LongMemEval_M (2.7 GB) never has to
/// sit in memory as a whole.
struct StreamSeq<F: FnMut(LmeItem) -> bool>(F);

impl<'de, F: FnMut(LmeItem) -> bool> DeserializeSeed<'de> for StreamSeq<F> {
    type Value = ();
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<(), D::Error> {
        d.deserialize_seq(self)
    }
}

impl<'de, F: FnMut(LmeItem) -> bool> Visitor<'de> for StreamSeq<F> {
    type Value = ();
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a JSON array of LongMemEval items")
    }
    fn visit_seq<A: SeqAccess<'de>>(mut self, mut seq: A) -> Result<(), A::Error> {
        while let Some(item) = seq.next_element::<LmeItem>()? {
            if !(self.0)(item) {
                // Drain without materialising the rest.
                while seq.next_element::<serde::de::IgnoredAny>()?.is_some() {}
                break;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct Selection {
    pub limit: Option<usize>,
    pub stride: usize,
    pub offset: usize,
    pub types: Option<Vec<String>>,
}

impl Selection {
    fn keep(&self, idx: usize) -> bool {
        idx >= self.offset && (idx - self.offset) % self.stride.max(1) == 0
    }
}

/// Load a dataset and call `sink` for every selected item (blocking; run on a blocking thread).
pub fn stream(name: &str, path: &Path, sel: &Selection, mut sink: impl FnMut(Item) -> anyhow::Result<()>) -> anyhow::Result<usize> {
    let mut sent = 0usize;
    if name.starts_with("longmemeval") {
        let f = std::fs::File::open(path).with_context(|| format!("open {} (run `memhouse bench download {name}`)", path.display()))?;
        let mut de = serde_json::Deserializer::from_reader(std::io::BufReader::with_capacity(1 << 20, f));
        let mut idx = 0usize;
        let mut err: Option<anyhow::Error> = None;
        StreamSeq(|it: LmeItem| {
            let i = idx;
            idx += 1;
            if sel.limit.is_some_and(|l| sent >= l) {
                return false;
            }
            if !sel.keep(i) {
                return true;
            }
            if let Some(ts) = &sel.types {
                if !ts.iter().any(|t| t == &it.question_type) {
                    return true;
                }
            }
            match sink(lme_to_item(it)) {
                Ok(()) => {
                    sent += 1;
                    true
                }
                Err(e) => {
                    err = Some(e);
                    false
                }
            }
        })
        .deserialize(&mut de)?;
        if let Some(e) = err {
            return Err(e);
        }
    } else if name == "locomo" {
        let text = std::fs::read_to_string(path).with_context(|| format!("open {} (run `memhouse bench download locomo`)", path.display()))?;
        let convs: Vec<serde_json::Value> = serde_json::from_str(&text)?;
        for (i, c) in convs.into_iter().enumerate() {
            if sel.limit.is_some_and(|l| sent >= l) {
                break;
            }
            if !sel.keep(i) {
                continue;
            }
            sink(locomo_to_item(&c, sel.types.as_deref())?)?;
            sent += 1;
        }
    } else {
        anyhow::bail!("no loader for {name}");
    }
    Ok(sent)
}

pub const LOCOMO_CATEGORIES: [(i64, &str); 5] = [(1, "multi-hop"), (2, "temporal"), (3, "open-domain"), (4, "single-hop"), (5, "adversarial")];

fn norm_dia(d: &str) -> Option<(u32, u32)> {
    static RE: once_cell::sync::Lazy<regex::Regex> = once_cell::sync::Lazy::new(|| regex::Regex::new(r"D:?(\d+):(\d+)").unwrap());
    let c = RE.captures(d)?;
    Some((c[1].parse().ok()?, c[2].parse().ok()?))
}

fn locomo_to_item(c: &serde_json::Value, types: Option<&[String]>) -> anyhow::Result<Item> {
    let conv = &c["conversation"];
    let id = c["sample_id"].as_str().unwrap_or("conv").to_string();
    let mut sessions = vec![];
    let mut n = 1;
    while let Some(turns) = conv.get(format!("session_{n}")).and_then(|v| v.as_array()) {
        let date = conv.get(format!("session_{n}_date_time")).and_then(|v| v.as_str()).and_then(parse_locomo_date);
        let sid = format!("session_{n}");
        let turns = turns
            .iter()
            .map(|t| {
                let dia = t["dia_id"].as_str().unwrap_or("");
                let ref_id = norm_dia(dia).map(|(s, t)| format!("D{s}:{t}")).unwrap_or_else(|| dia.to_string());
                let mut content = t["text"].as_str().unwrap_or("").to_string();
                if let Some(cap) = t.get("blip_caption").and_then(|v| v.as_str()) {
                    content.push_str(&format!(" [shares a photo: {cap}]"));
                }
                Turn { role: t["speaker"].as_str().unwrap_or("speaker").to_string(), content, ref_id, evidence: false }
            })
            .collect();
        sessions.push(Session { id: sid, date, turns });
        n += 1;
    }
    let mut questions = vec![];
    for (qi, q) in c["qa"].as_array().map(|a| a.as_slice()).unwrap_or(&[]).iter().enumerate() {
        let cat = q["category"].as_i64().unwrap_or(0);
        let qtype = LOCOMO_CATEGORIES.iter().find(|(k, _)| *k == cat).map(|(_, n)| n.to_string()).unwrap_or_else(|| format!("cat{cat}"));
        if let Some(ts) = types {
            if !ts.iter().any(|t| t == &qtype) {
                continue;
            }
        } else if cat == 5 {
            continue; // adversarial questions are excluded by convention
        }
        let evidence: Vec<(u32, u32)> = q["evidence"].as_array().map(|a| a.iter().filter_map(|e| e.as_str().and_then(norm_dia)).collect()).unwrap_or_default();
        let mut ev_sessions: Vec<String> = evidence.iter().map(|(s, _)| format!("session_{s}")).collect();
        ev_sessions.sort();
        ev_sessions.dedup();
        let answer = q.get("answer").map(json_to_string).or_else(|| q.get("adversarial_answer").map(json_to_string)).unwrap_or_default();
        questions.push(Question {
            id: format!("{id}#q{qi}"),
            qtype,
            question: q["question"].as_str().unwrap_or("").to_string(),
            answer,
            date: None,
            evidence_sessions: ev_sessions,
            evidence_turns: evidence.iter().map(|(s, t)| format!("D{s}:{t}")).collect(),
            abstention: cat == 5,
        });
    }
    Ok(Item { conv_id: id, sessions, questions, per_message: true })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dates() {
        assert_eq!(parse_lme_date("2023/05/20 (Sat) 02:21").unwrap().to_rfc3339(), "2023-05-20T02:21:00+00:00");
        assert_eq!(parse_locomo_date("1:56 pm on 8 May, 2023").unwrap().to_rfc3339(), "2023-05-08T13:56:00+00:00");
        assert_eq!(parse_locomo_date("12:04 am on 20 January, 2023").unwrap().to_rfc3339(), "2023-01-20T00:04:00+00:00");
        assert_eq!(norm_dia("D:11:26"), Some((11, 26)));
        assert_eq!(norm_dia("D30:05"), Some((30, 5)));
    }
}
