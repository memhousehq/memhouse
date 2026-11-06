// SPDX-License-Identifier: Apache-2.0
//! The write gate's reading of a statement (QUAL-02) and intake routing (HYB-01).
//!
//! [`RuleClassifier`] decides without a model: deterministic, free and testable, so the
//! governance suite never depends on one. [`ChatClassifier`] puts a small chat model behind the
//! same [`Classifier`] interface and falls back to the rules when the model fails; tiering the
//! two by confidence (ECON-04) comes with G14.

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

fn re(p: &str) -> Regex {
    Regex::new(&format!("(?i){p}")).expect("valid regex")
}

/// Hedges, rumours and hypotheticals. Checked first: a hedged correction must not supersede.
static SPECULATION: Lazy<Regex> = Lazy::new(|| {
    re(
        r"\b(?:might|maybe|perhaps|possibly|probably|presumably|could be|may be|may have|might have|i think|i guess|i suspect|i wonder|wondering whether|wondering if|not sure|unsure whether|rumou?red|rumou?rs?|supposedly|allegedly|apparently|hypothetically|in theory|considering (?:whether|switching|moving|leaving|buying)|thinking (?:about|of) (?:switching|moving|leaving|buying|getting|selling)|if (?:we|i|they|he|she|you) (?:were|had|could|would))\b",
    )
});

/// A change to something stored before.
static CORRECTION: Lazy<Regex> = Lazy::new(|| {
    re(
        r"\b(?:actually|correction|to correct|i was wrong|was wrong about|no longer|not anymore|any ?more\b|instead of|has changed|have changed|changed (?:to|from|jobs?|address|teams?|roles?|(?:her|his|their|its|my|our|the) )|switched (?:to|from|over)|moved (?:to|from|out|back|away)|relocated|now (?:lives?|living|works?|working|has|have|owns?|uses?|using|prefers?|is|are|at|in|on)|(?:is|are|was) now|updated (?:to|from)|replaced (?:by|with)|used to (?:be|live|work|have|own|use|prefer))\b",
    )
});

/// An intention not yet carried out.
static PLAN: Lazy<Regex> = Lazy::new(|| {
    re(
        r"\b(?:plans? to|planning to|planned to|plans? (?:a|an|the|on)|going to|gonna|intends? to|intending to|intention (?:is|was) to|will (?:be (?:going|visiting|starting|moving|traveling|travelling)|visit|start|move|travel|go|buy|sign|launch|ship|join|leave|call|send|meet|attend|try|take|get|book|renew|cancel|switch|upgrade|review|decide|finish|begin)|(?:i|we|he|she|they)'ll|wants? to|would like to|hopes? to|hoping to|aims? to|aiming to|next (?:week|month|year|quarter|monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekend|spring|summer|autumn|fall|winter)|tomorrow|later this (?:week|month|year)|this coming|remember to|needs? to|has to|have to)\b",
    )
});

static PREFERENCE: Lazy<Regex> =
    Lazy::new(|| re(r"\b(?:prefers?|preferred|preference|likes?|loves?|enjoys?|hates?|dislikes?|favou?rite|rather than|can'?t stand|fond of|allergic to)\b"));

static INSTRUCTION: Lazy<Regex> =
    Lazy::new(|| re(r"^\s*(?:always|never|do not|don'?t|make sure|be sure|use|run|avoid|ensure|prefer)\b|\b(?:should always|must always|should never|must never)\b"));

/// Past events: a dated reference or a completed action.
static EVENT: Lazy<Regex> = Lazy::new(|| {
    re(
        r"\b(?:yesterday|last (?:week|month|year|night|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday|spring|summer|autumn|fall|winter)|\d+ (?:days?|weeks?|months?|years?) ago|ago\b|bought|sold|visited|went|adopted|started|finished|completed|signed|joined|left|met|attended|graduated|married|received|launched|shipped|renewed|cancell?ed|paid|booked|ordered|returned|travell?ed|won|lost|got|gave|took|made|did|had|was born|passed away|celebrated|hired|fired|quit|retired|purchased|upgraded|downgraded)\b",
    )
});

/// The deterministic statement classifier (QUAL-02). Markers are checked in order:
/// speculation, correction, plan, preference, instruction, event; anything else is a fact.
pub struct RuleClassifier;

impl RuleClassifier {
    pub fn classify_text(text: &str, kind: MemoryKind) -> Classification {
        let hit =
            |statement: Statement, re: &Regex| re.find(text).map(|m| Classification { statement, confidence: 0.8, reason: format!("rules: \"{}\"", m.as_str().to_lowercase()) });
        hit(Statement::Speculation, &SPECULATION)
            .or_else(|| hit(Statement::Correction, &CORRECTION))
            .or_else(|| hit(Statement::Plan, &PLAN))
            .or_else(|| match kind {
                MemoryKind::Preference => Some(Classification { statement: Statement::Preference, confidence: 0.8, reason: "rules: kind preference".into() }),
                MemoryKind::Procedural => Some(Classification { statement: Statement::Instruction, confidence: 0.8, reason: "rules: kind procedural".into() }),
                _ => None,
            })
            .or_else(|| hit(Statement::Preference, &PREFERENCE))
            .or_else(|| hit(Statement::Instruction, &INSTRUCTION))
            .or_else(|| hit(Statement::Event, &EVENT))
            .unwrap_or(Classification { statement: Statement::Fact, confidence: 0.6, reason: "rules: no marker".into() })
    }
}

#[async_trait]
impl Classifier for RuleClassifier {
    fn id(&self) -> String {
        "rules-v1".into()
    }
    async fn classify(&self, text: &str, kind: MemoryKind) -> anyhow::Result<Classification> {
        Ok(Self::classify_text(text, kind))
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
    async fn classify(&self, text: &str, kind: MemoryKind) -> anyhow::Result<Classification> {
        let prompt = format!("{CLASSIFY_PROMPT}{}", text.chars().take(2000).collect::<String>());
        match self.chat.chat(CLASSIFY_SYSTEM, &prompt).await {
            Ok((answer, _)) => match Self::parse(&answer) {
                Some((statement, confidence)) => Ok(Classification { statement, confidence, reason: self.id() }),
                None => {
                    tracing::warn!("classifier {} gave an unusable answer; using the rules", self.id());
                    Ok(RuleClassifier::classify_text(text, kind))
                }
            },
            Err(e) => {
                tracing::warn!("classifier {} failed ({e:#}); using the rules", self.id());
                Ok(RuleClassifier::classify_text(text, kind))
            }
        }
    }
}

static CODE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?m)```|^\s*(?:fn |pub fn |def |class |impl |import |from \S+ import |#include|func |public (?:static )?\w+ |const \w+ = |let \w+ = |SELECT .+ FROM )|[;{]\s*$")
        .expect("valid regex")
});

static RELATIONSHIP: Lazy<Regex> = Lazy::new(|| {
    re(
        r"\b(?:is|was|are|were|became) (?:now )?(?:the |a |an |their |his |her |our |my )?(?:new )?(?:manager|boss|colleague|co-?worker|teammate|wife|husband|partner|spouse|girlfriend|boyfriend|brother|sister|mother|father|mom|dad|son|daughter|friend|cousin|uncle|aunt|neighbou?r|mentor|customer|client|vendor|supplier|owner|founder|ceo|cto|cfo|champion|sponsor|contact|account manager) (?:of|for|at|to)\b|\b(?:reports to|works for|works with|married to|engaged to|is related to|is managed by)\b",
    )
});

/// Intake routing (HYB-01): which representation a record goes to. Rounds of a conversation are
/// narrative; a record with a structured form is structured; code is stored as text with a
/// `code` tag until code-aware memory (requirement decision 16).
pub fn route(kind: MemoryKind, content: &str, structured: bool, code_refs: bool) -> Route {
    if kind == MemoryKind::Episodic {
        return Route::Narrative;
    }
    if structured {
        return Route::Structured;
    }
    if code_refs || CODE.find_iter(content).count() >= 2 || content.contains("```") {
        return Route::Code;
    }
    if RELATIONSHIP.is_match(content) {
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

/// Content words two statements share (a correction must share one with what it supersedes).
pub fn shares_content_word(a: &str, b: &str) -> bool {
    const STOP: &[&str] = &[
        "the",
        "user",
        "users",
        "that",
        "this",
        "with",
        "from",
        "have",
        "has",
        "had",
        "now",
        "they",
        "their",
        "them",
        "there",
        "were",
        "been",
        "being",
        "about",
        "into",
        "than",
        "then",
        "when",
        "what",
        "which",
        "will",
        "would",
        "also",
        "just",
        "very",
        "some",
        "more",
        "most",
        "other",
        "only",
        "over",
        "such",
        "your",
        "yours",
        "ours",
        "longer",
        "actually",
        "anymore",
        "instead",
        "changed",
        "switched",
        "moved",
        "updated",
        "used",
        "currently",
    ];
    let words = |s: &str| -> std::collections::HashSet<String> {
        s.split(|c: char| !c.is_alphanumeric())
            .map(|w| w.to_lowercase())
            .filter(|w| (w.len() >= 4 || w.chars().any(|c| c.is_ascii_digit())) && !STOP.contains(&w.as_str()))
            .collect()
    };
    let (wa, wb) = (words(a), words(b));
    wa.iter().any(|w| wb.contains(w) || wb.iter().any(|x| x.len() >= 5 && w.len() >= 5 && (x.starts_with(&w[..5]) || w.starts_with(&x[..5]))))
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(route(MemoryKind::Episodic, "user: hi", false, false), Route::Narrative);
        assert_eq!(route(MemoryKind::Semantic, "order A-1001 shipped", true, false), Route::Structured);
        assert_eq!(route(MemoryKind::Semantic, "fn main() {\n    println!(\"hi\");\n}", false, false), Route::Code);
        assert_eq!(route(MemoryKind::Semantic, "Priya is the champion for the Acme account.", false, false), Route::Relationship);
        assert_eq!(route(MemoryKind::Semantic, "Acme renews on 1 March.", false, false), Route::Fact);
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
    }

    #[test]
    fn chat_answers_parse() {
        assert_eq!(ChatClassifier::parse("```json\n{\"statement\": \"Plan\", \"confidence\": 0.9}\n```"), Some((Statement::Plan, 0.9)));
        assert_eq!(ChatClassifier::parse("{\"statement\": \"nonsense\"}"), None);
    }
}
