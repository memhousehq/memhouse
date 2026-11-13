// SPDX-License-Identifier: Apache-2.0
//! The write gate's reading of a statement (QUAL-02) and intake routing (HYB-01).
//!
//! The markers and word lists are data: they come from the language pack of the text
//! ([`crate::lang`]). [`RuleClassifier`] decides without a model: deterministic, free and testable, so the
//! governance suite never depends on one. [`ChatClassifier`] puts a small chat model behind the
//! same [`Classifier`] interface and falls back to the rules when the model fails; tiering the
//! two by confidence (ECON-04) comes with G14.

use crate::lang::{Detected, Languages, Pack, ValueRules};
use crate::traits::{ChatModel, Classifier};
use crate::types::*;
use async_trait::async_trait;
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// What a classifier read a statement as.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Classification {
    pub statement: Statement,
    /// 0 to 1: how sure the classifier is (rules: 0.8 on a marker, 0.6 for the default).
    pub confidence: f32,
    /// The marker or model that decided, for the audit log.
    pub reason: String,
}

/// The markers that decided, most cautious first when packs disagree: a statement one enabled
/// language reads as a guess or a plan is held, whatever another reads it as.
fn caution(s: Statement) -> u8 {
    match s {
        Statement::Speculation => 0,
        Statement::Plan => 1,
        Statement::Correction => 2,
        _ => 3,
    }
}

impl Pack {
    /// What this pack's markers read `text` as; `None` when it has no marker. Markers are
    /// checked in order: speculation, correction, plan, preference, instruction, event.
    pub fn marker(&self, text: &str, kind: MemoryKind) -> Option<Classification> {
        let hit = |statement: Statement, re: &Option<Regex>| {
            re.as_ref().and_then(|re| re.find(text)).map(|m| Classification { statement, confidence: 0.8, reason: format!("rules: \"{}\"", m.as_str().to_lowercase()) })
        };
        hit(Statement::Speculation, &self.speculation)
            .or_else(|| hit(Statement::Correction, &self.correction))
            .or_else(|| hit(Statement::Plan, &self.plan))
            .or_else(|| match kind {
                MemoryKind::Preference => Some(Classification { statement: Statement::Preference, confidence: 0.8, reason: "rules: kind preference".into() }),
                MemoryKind::Procedural => Some(Classification { statement: Statement::Instruction, confidence: 0.8, reason: "rules: kind procedural".into() }),
                _ => None,
            })
            .or_else(|| hit(Statement::Preference, &self.preference))
            .or_else(|| hit(Statement::Instruction, &self.instruction))
            .or_else(|| hit(Statement::Event, &self.event))
    }

    /// The rules' reading of `text` in this language; a statement with no marker is a fact.
    pub fn classify_text(&self, text: &str, kind: MemoryKind) -> Classification {
        self.marker(text, kind).unwrap_or(Classification { statement: Statement::Fact, confidence: 0.6, reason: "rules: no marker".into() })
    }
}

impl Detected {
    /// The rules' reading of `text` (QUAL-02). A text whose language was detected is read by
    /// that language's markers. One whose language was not is read by every enabled pack, and
    /// the most cautious reading wins: detection must not let a plan through as a fact.
    pub fn classify_text(&self, text: &str, kind: MemoryKind) -> Classification {
        if self.sure || self.others.is_empty() {
            return self.pack.classify_text(text, kind);
        }
        let mut best = self.pack.marker(text, kind);
        for p in &self.others {
            if let Some(c) = p.marker(text, kind) {
                if best.as_ref().is_none_or(|b| caution(c.statement) < caution(b.statement)) {
                    best = Some(c);
                }
            }
        }
        best.unwrap_or(Classification { statement: Statement::Fact, confidence: 0.6, reason: "rules: no marker".into() })
    }
}

/// The deterministic statement classifier (QUAL-02): the markers of the text's language pack.
pub struct RuleClassifier;

impl RuleClassifier {
    /// The reading by the built-in English pack.
    pub fn classify_text(text: &str, kind: MemoryKind) -> Classification {
        Languages::english().default_pack().classify_text(text, kind)
    }
}

#[async_trait]
impl Classifier for RuleClassifier {
    fn id(&self) -> String {
        "rules-v1".into()
    }
    async fn classify(&self, text: &str, kind: MemoryKind, lang: &Detected) -> anyhow::Result<Classification> {
        Ok(lang.classify_text(text, kind))
    }
}

const CLASSIFY_SYSTEM: &str = "You classify one statement for a memory system. Output JSON only.";

const CLASSIFY_PROMPT: &str = r#"Classify the statement as exactly one of:
- fact: something true now
- event: something that happened
- correction: a change to, or fix of, something said before ("now", "no longer", "actually", "moved to")
- plan: an intention not yet carried out
- speculation: a guess, rumour, hypothetical or hedged claim
- preference: a like, dislike or way of working
- instruction: how something should be done
Answer {"statement": "<one word>", "confidence": <0 to 1>}.

Statement: "#;

/// Added to the prompt when the tenant has more than one language. With one language the
/// prompt is unchanged, so cached answers stay valid.
const CLASSIFY_ANY_LANGUAGE: &str = "The statement may be in any language; the marker words above are examples in English. Classify it by its meaning.\n\n";

/// A small chat model as the gate's classifier, behind the same interface (TR-MS-01). The rules
/// answer whenever the model fails or answers something unusable.
pub struct ChatClassifier {
    pub chat: Arc<dyn ChatModel>,
}

#[derive(Deserialize)]
struct ChatAnswer {
    statement: String,
    #[serde(default)]
    confidence: Option<f32>,
}

impl ChatClassifier {
    fn parse(answer: &str) -> Option<(Statement, f32)> {
        let start = answer.find('{')?;
        let end = answer.rfind('}')?;
        let a: ChatAnswer = serde_json::from_str(answer.get(start..=end)?).ok()?;
        Some((Statement::parse(&a.statement)?, a.confidence.unwrap_or(0.7).clamp(0.0, 1.0)))
    }
}

#[async_trait]
impl Classifier for ChatClassifier {
    fn id(&self) -> String {
        format!("llm:{}", self.chat.id())
    }
    async fn classify(&self, text: &str, kind: MemoryKind, lang: &Detected) -> anyhow::Result<Classification> {
        let head = if lang.multilingual { CLASSIFY_PROMPT.replace("Statement: ", &format!("{CLASSIFY_ANY_LANGUAGE}Statement: ")) } else { CLASSIFY_PROMPT.to_string() };
        let prompt = format!("{head}{}", text.chars().take(2000).collect::<String>());
        match self.chat.chat(CLASSIFY_SYSTEM, &prompt).await {
            Ok((answer, _)) => match Self::parse(&answer) {
                Some((statement, confidence)) => Ok(Classification { statement, confidence, reason: self.id() }),
                None => {
                    tracing::warn!("classifier {} gave an unusable answer; using the rules", self.id());
                    Ok(lang.classify_text(text, kind))
                }
            },
            Err(e) => {
                tracing::warn!("classifier {} failed ({e:#}); using the rules", self.id());
                Ok(lang.classify_text(text, kind))
            }
        }
    }
}

static CODE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?m)```|^\s*(?:fn |pub fn |def |class |impl |import |from \S+ import |#include|func |public (?:static )?\w+ |const \w+ = |let \w+ = |SELECT .+ FROM )|[;{]\s*$")
        .expect("valid regex")
});

/// Intake routing (HYB-01): which representation a record goes to. Rounds of a conversation are
/// narrative; a record with a structured form is structured; code is stored as text with a
/// `code` tag until code-aware memory (requirement decision 16). `pack` is the record's language:
/// its relationship patterns decide what is routed as a relationship.
pub fn route(pack: &Pack, kind: MemoryKind, content: &str, structured: bool, code_refs: bool) -> Route {
    if kind == MemoryKind::Episodic {
        return Route::Narrative;
    }
    if structured {
        return Route::Structured;
    }
    if code_refs || CODE.find_iter(content).count() >= 2 || content.contains("```") {
        return Route::Code;
    }
    if pack.relationship.as_ref().is_some_and(|re| re.is_match(content)) {
        return Route::Relationship;
    }
    let sentences = content.split(['.', '!', '?', '\n']).filter(|s| s.split_whitespace().count() >= 3).count();
    if sentences > 3 || content.chars().count() > 600 || kind == MemoryKind::Document {
        Route::Narrative
    } else {
        Route::Fact
    }
}

/// A JSON object with a `record_type` written as content is a structured record (HYB-01): its
/// attributes go to the structured table and its text becomes `type: key=value, ...`.
pub fn structured_from_content(content: &str) -> Option<(Structured, String)> {
    let t = content.trim();
    if !t.starts_with('{') {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(t).ok()?;
    let mut o = v.as_object()?.clone();
    let record_type = o.remove("record_type")?.as_str()?.trim().to_string();
    if record_type.is_empty() || o.is_empty() {
        return None;
    }
    let attrs = serde_json::Value::Object(o);
    let text = structured_text(&record_type, &attrs);
    Some((Structured { record_type, attrs }, text))
}

/// The text form of a structured record, for keyword and vector search.
pub fn structured_text(record_type: &str, attrs: &serde_json::Value) -> String {
    let fields: Vec<String> = attrs
        .as_object()
        .map(|o| {
            o.iter()
                .map(|(k, v)| match v {
                    serde_json::Value::String(s) => format!("{k}={s}"),
                    v => format!("{k}={v}"),
                })
                .collect()
        })
        .unwrap_or_default();
    format!("{record_type}: {}", fields.join(", "))
}

impl ValueRules {
    /// Content words two statements share (a correction must share one with what it supersedes).
    pub fn shares_content_word(&self, a: &str, b: &str) -> bool {
        let words = |s: &str| -> std::collections::HashSet<String> {
            s.split(|c: char| !c.is_alphanumeric())
                .map(|w| w.to_lowercase())
                .filter(|w| (w.chars().count() >= 4 || w.chars().any(|c| c.is_ascii_digit())) && !self.stop.contains(w.as_str()))
                .collect()
        };
        let (wa, wb) = (words(a), words(b));
        // The same stem: five letters in common at the start. Counted in characters, so a word with
        // letters outside ASCII ("Kraków") is cut between letters, never inside one.
        let stem = |w: &str| w.char_indices().nth(5).map(|(i, _)| w[..i].to_string()).or_else(|| (w.chars().count() == 5).then(|| w.to_string()));
        wa.iter().any(|w| {
            wb.contains(w)
                || stem(w).is_some_and(|sw| {
                    wb.iter().any(|x| match stem(x) {
                        Some(sx) => x.starts_with(&sw) || w.starts_with(&sx),
                        None => false,
                    })
                })
        })
    }

    /// The quantities a statement states (numbers, amounts, durations, counts), dates and
    /// identifiers left out. Number words become digits, so "three" and "3" are the same value.
    fn quantities(&self, s: &str) -> std::collections::BTreeSet<String> {
        let s = s.to_lowercase();
        let undated = self.dates.replace_all(&s, " ");
        let undated = self.identifier.replace_all(&undated, " ");
        self.quantity
            .find_iter(&undated)
            .map(|m| {
                let q = m.as_str().trim_end_matches(['.', ',']);
                self.numbers.get(q).cloned().unwrap_or_else(|| q.to_string())
            })
            .filter(|q| !q.is_empty())
            .collect()
    }

    /// The content words of a statement, without its quantities, dates and function words.
    fn value_words(&self, s: &str) -> std::collections::BTreeSet<String> {
        let s = s.to_lowercase();
        let undated = self.dates.replace_all(&s, " ");
        let undated = self.identifier.replace_all(&undated, " ");
        let plain = self.quantity.replace_all(&undated, " ");
        plain.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() >= 3 && !self.value_stop.contains(*w) && !self.months.contains(*w)).map(String::from).collect()
    }

    /// `new` restates `old` with a changed value ("three bikes" → "four bikes", "$350,000" →
    /// "$400,000", "twice a week" → "three times a week"): an update even without a correction
    /// marker (QUAL-01). Both state a quantity, the quantities differ on both sides, and the rest of
    /// the statement is the same (`min_overlap` of the shorter one's content words, at least two).
    pub fn value_update(&self, old: &str, new: &str, min_overlap: f32) -> bool {
        let (qo, qn) = (self.quantities(old), self.quantities(new));
        if qo.is_empty() || qn.is_empty() || qo.is_subset(&qn) || qn.is_subset(&qo) {
            return false;
        }
        let (wo, wn) = (self.value_words(old), self.value_words(new));
        // People and animals a statement can be about: a value of the user's sister is not the user's.
        if wo.symmetric_difference(&wn).any(|w| self.people.contains(w.as_str())) {
            return false;
        }
        let small = wo.len().min(wn.len());
        if small < 2 {
            return false;
        }
        let shared = wo.intersection(&wn).count();
        shared as f32 / small as f32 >= min_overlap
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn en() -> std::sync::Arc<Pack> {
        Languages::english().default_pack().clone()
    }

    fn shares_content_word(a: &str, b: &str) -> bool {
        Languages::english().values().shares_content_word(a, b)
    }

    fn value_update(old: &str, new: &str, min_overlap: f32) -> bool {
        Languages::english().values().value_update(old, new, min_overlap)
    }

    fn st(text: &str) -> Statement {
        RuleClassifier::classify_text(text, MemoryKind::Semantic).statement
    }

    #[test]
    fn reads_the_seven_statement_types() {
        assert_eq!(st("Acme's renewal date is 1 March 2027."), Statement::Fact);
        assert_eq!(st("The user adopted a cat named Miso last week."), Statement::Event);
        assert_eq!(st("Actually, the user moved to Porto."), Statement::Correction);
        assert_eq!(st("The user no longer works at Initech."), Statement::Correction);
        assert_eq!(st("The user now has four bikes."), Statement::Correction);
        assert_eq!(st("The user plans to visit Japan in May."), Statement::Plan);
        assert_eq!(st("We are going to migrate to Postgres 17 next quarter."), Statement::Plan);
        assert_eq!(st("The customer might switch vendors."), Statement::Speculation);
        assert_eq!(st("I think she probably moved to Berlin."), Statement::Speculation);
        assert_eq!(st("The user prefers window seats."), Statement::Preference);
        assert_eq!(st("Always run cargo fmt before committing."), Statement::Instruction);
        assert_eq!(RuleClassifier::classify_text("Run the tests first.", MemoryKind::Procedural).statement, Statement::Instruction);
    }

    #[test]
    fn hedged_corrections_are_speculation() {
        assert_eq!(st("Bob might have moved to Lisbon."), Statement::Speculation);
    }

    #[test]
    fn routes_by_data_type() {
        assert_eq!(route(&en(), MemoryKind::Episodic, "user: hi", false, false), Route::Narrative);
        assert_eq!(route(&en(), MemoryKind::Semantic, "order A-1001 shipped", true, false), Route::Structured);
        assert_eq!(route(&en(), MemoryKind::Semantic, "fn main() {\n    println!(\"hi\");\n}", false, false), Route::Code);
        assert_eq!(route(&en(), MemoryKind::Semantic, "Priya is the champion for the Acme account.", false, false), Route::Relationship);
        assert_eq!(route(&en(), MemoryKind::Semantic, "Acme renews on 1 March.", false, false), Route::Fact);
    }

    #[test]
    fn json_content_is_a_structured_record() {
        let (s, text) = structured_from_content(r#"{"record_type": "order", "order_id": "A-1001", "status": "shipped"}"#).unwrap();
        assert_eq!(s.record_type, "order");
        assert_eq!(s.attrs["order_id"], "A-1001");
        assert_eq!(text, "order: order_id=A-1001, status=shipped");
        assert!(structured_from_content(r#"{"order_id": "A-1001"}"#).is_none());
        assert!(structured_from_content("not json").is_none());
    }

    #[test]
    fn corrections_need_a_shared_word() {
        assert!(shares_content_word("The user lives in Lisbon.", "The user now lives in Porto."));
        assert!(shares_content_word("The user has three bikes.", "The user now has four bikes."));
        assert!(!shares_content_word("The user likes jazz.", "The user now works at Globex."));
        // Letters outside ASCII: no cut inside a letter (this panicked), and stems still match.
        assert!(shares_content_word("Dana lives in Kraków.", "Correction: Dana lives in Kraków's old town now."));
        assert!(shares_content_word("Krakówie", "Krakówku"));
        assert!(!shares_content_word("Krakówie", "Krajobraz"));
        assert!(!shares_content_word("Jo likes Malmö.", "Jo now works at Škoda."));
    }

    #[test]
    fn value_updates_restate_with_a_changed_quantity() {
        // From the LongMemEval knowledge-update sample.
        assert!(value_update("The user currently owns three bikes in total.", "The user owns four bikes in total.", 0.6));
        assert!(value_update("The user recently set a personal best time of 27:12 in a charity 5K run.", "The user's personal best time for a 5K run is 25:50.", 0.6));
        assert!(value_update("The user got pre-approved for $350,000 from Wells Fargo.", "The user was pre-approved for $400,000 from Wells Fargo.", 0.6));
        assert!(value_update("The user practices yoga twice a week.", "The user attends yoga classes three times a week.", 0.6));
        assert!(value_update(
            "The user spent around 5-6 hours working on their abstract ocean sculpture as of June 11, 2023.",
            "The user has been working on an abstract ocean sculpture for 10-12 hours as of 2023-06-17.",
            0.9
        ));
        // Not updates: no quantity changed, only a date, a different thing, or an added number.
        assert!(!value_update("The user is training for a charity 5K run.", "The user's personal best time for a 5K run is 25:50.", 0.6));
        assert!(!value_update("The user went to the gym on 2023-05-01.", "The user went to the gym on 2023-06-01.", 0.6));
        assert!(!value_update("The user bought 2 new plants.", "The user bought 3 succulents.", 0.6));
        assert!(!value_update("The user owns a road bike.", "The user has put 2,000 miles on their road bike.", 0.6));
        // Seen in the sample: the same value in words and digits, another person, a decade.
        assert!(!value_update("The user has been taking dance classes for about 3 months.", "The user has been taking cooking classes for about three months.", 0.6));
        assert!(!value_update("The user's sister is 35 years old.", "The user is 32 years old.", 0.6));
        assert!(!value_update("The user owns a Leica IIIa camera with a 50mm f/2 lens.", "The user owns a 1940s-era Leica IIIa camera.", 0.6));
        // Identifiers are not values: different invoices, orders, customers.
        assert!(!value_update("Customer kqzpfa prefers email for invoice 1000", "Customer wbtnoe prefers email for invoice 1004", 0.6));
        assert!(!value_update("Order A-1001 shipped on Monday.", "Order A-1002 shipped on Monday.", 0.6));
    }

    #[test]
    fn chat_answers_parse() {
        assert_eq!(ChatClassifier::parse("```json\n{\"statement\": \"Plan\", \"confidence\": 0.9}\n```"), Some((Statement::Plan, 0.9)));
        assert_eq!(ChatClassifier::parse("{\"statement\": \"nonsense\"}"), None);
    }
}
