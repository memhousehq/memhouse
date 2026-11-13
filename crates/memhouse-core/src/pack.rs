// SPDX-License-Identifier: Apache-2.0
//! The last steps of a recall (roadmap G12), after retrieval and fusion and with every access
//! filter already applied by the store:
//!
//! - **ranking** (HYB-05): the final score combines relevance, recency, confidence and validity
//!   with the weights of the compiled policy;
//! - **near-duplicate removal** (ECON-03): of memories that say the same thing, by vector
//!   (cosine) or by text (three-word shingles), only the best-ranked is returned;
//! - **the token budget** (PERF-06, PR-12): a hard cap on what is returned, the rendered block
//!   included;
//! - **rendering** (INT-04): the returned memories as one text block, in the form the request
//!   picks.
//!
//! Nothing here calls a model or the store.

use crate::policy::Ranking;
use crate::types::{ExcludedRecord, ExclusionReason, Hit, Memory, MemoryKind, MemoryStatus, RankFeatures, RenderFormat};
use chrono::{DateTime, Utc};
use std::collections::HashSet;

/// Rough token estimate (4 bytes per token), the unit of the token budget.
pub fn approx_tokens(s: &str) -> usize {
    s.len().div_ceil(4)
}

/// 1 for a confirmed record that is valid at `present`, 0.5 for a candidate (a held plan or a
/// proposal: not confirmed), 0 for a record that is no longer valid at `present`. Only an `as_of`
/// recall returns the last kind: the store already leaves out what was not valid at the recall's
/// own time.
pub fn validity(m: &Memory, present: DateTime<Utc>) -> f32 {
    let over = m.valid_to.is_some_and(|t| t <= present) || m.expires_at.is_some_and(|t| t <= present) || m.valid_from > present;
    match m.status {
        _ if over => 0.0,
        MemoryStatus::Committed => 1.0,
        MemoryStatus::Candidate => 0.5,
        _ => 0.0,
    }
}

/// The features of one hit. `now` is the recall's time (its `as_of`, or the present), which
/// recency is measured from; `present` is the wall clock, which validity is measured at.
pub fn features(h: &Hit, rank: &Ranking, now: DateTime<Utc>, present: DateTime<Utc>) -> RankFeatures {
    let m = &h.memory;
    let t = m.occurred_at.unwrap_or(m.created_at);
    let age = (now - t).num_seconds().max(0) as f32 / 86_400.0;
    RankFeatures { relevance: h.score, recency: 1.0 / (1.0 + age / rank.recency_half_life_days.max(1.0)), confidence: m.confidence.clamp(0.0, 1.0), validity: validity(m, present) }
}

/// Whether the policy's weights change the order relevance alone gives.
pub fn reorders(rank: &Ranking) -> bool {
    rank.recency_weight > 0.0 || rank.confidence_weight > 0.0 || rank.validity_weight > 0.0 || rank.relevance_weight != 1.0
}

/// Give every hit its final score (HYB-05):
/// `relevance_weight × relevance + recency_weight × recency + confidence_weight × confidence +
/// validity_weight × validity`, and order by it. With the default weights (1, 0, 0, 0) the score
/// and the order are the relevance order, untouched.
pub fn score(hits: &mut [Hit], rank: &Ranking, now: DateTime<Utc>, present: DateTime<Utc>) {
    let reorder = reorders(rank);
    for h in hits.iter_mut() {
        let f = features(h, rank, now, present);
        h.features = Some(f);
        if reorder {
            h.score = rank.relevance_weight * f.relevance + rank.recency_weight * f.recency + rank.confidence_weight * f.confidence + rank.validity_weight * f.validity;
        }
    }
    if reorder {
        hits.sort_by(|a, b| b.score.total_cmp(&a.score));
    }
}

/// The three-word shingles of a text, over lower-cased words of letters and digits. A text of
/// one or two words is one shingle.
pub fn shingles(text: &str) -> HashSet<u64> {
    use std::hash::{Hash, Hasher};
    let words: Vec<String> = text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(|w| w.to_lowercase()).collect();
    let hash = |ws: &[String]| {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        ws.hash(&mut h);
        h.finish()
    };
    if words.is_empty() {
        return HashSet::new();
    }
    if words.len() < 3 {
        return HashSet::from([hash(&words)]);
    }
    words.windows(3).map(hash).collect()
}

/// Jaccard overlap of two shingle sets (0 when either is empty).
pub fn overlap(a: &HashSet<u64>, b: &HashSet<u64>) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let both = a.intersection(b).count();
    both as f32 / (a.len() + b.len() - both) as f32
}

/// Cosine similarity of two vectors (0 when they can't be compared).
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let (mut dot, mut na, mut nb) = (0.0f64, 0.0f64, 0.0f64);
    for (x, y) in a.iter().zip(b) {
        dot += f64::from(*x) * f64::from(*y);
        na += f64::from(*x) * f64::from(*x);
        nb += f64::from(*y) * f64::from(*y);
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    (dot / (na.sqrt() * nb.sqrt())) as f32
}

/// Why two hits are near-duplicates under the policy's thresholds, if they are.
///
/// Two episodic records of different sessions are different events, however alike their words:
/// "we reviewed the proposal" in March and again in August are both kept, since a question may
/// be about either or about how often.
fn duplicate_of(a: &Hit, a_sh: &HashSet<u64>, b: &Hit, b_sh: &HashSet<u64>, rank: &Ranking) -> Option<String> {
    if a.memory.kind == MemoryKind::Episodic && b.memory.kind == MemoryKind::Episodic && a.memory.session_id != b.memory.session_id {
        return None;
    }
    if let (Some(x), Some(y)) = (&a.embedding, &b.embedding) {
        let c = cosine(x, y);
        if c >= rank.dedup_cosine {
            return Some(format!("cosine {c:.3} with {} (threshold {})", a.memory.id, rank.dedup_cosine));
        }
    }
    let o = overlap(a_sh, b_sh);
    (o >= rank.dedup_overlap).then(|| format!("text overlap {o:.3} with {} (threshold {})", a.memory.id, rank.dedup_overlap))
}

/// Near-duplicate removal (ECON-03): walk `hits` in rank order and keep a hit only if it is not
/// a near-duplicate of one already kept, then fill the places this frees, up to `k`, from
/// `reserve` (the candidates ranked just below, in order) under the same rule. Of a confirmed
/// record and a candidate that say the same, the confirmed one is kept wherever it ranked.
/// An exact structured match is never dropped for a similar memory.
pub fn dedup(hits: Vec<Hit>, reserve: Vec<Hit>, k: usize, rank: &Ranking, cut: &mut Vec<ExcludedRecord>) -> Vec<Hit> {
    if !rank.dedup {
        return hits;
    }
    let head = hits.len();
    let mut kept: Vec<(Hit, HashSet<u64>)> = Vec::with_capacity(head);
    for (i, h) in hits.into_iter().chain(reserve).enumerate() {
        // The reserve only fills places that removing duplicates freed. Once they are filled it
        // can still give the confirmed record of a candidate that was kept, never a new place.
        let full = i >= head && kept.len() >= head.min(k);
        let sh = shingles(&h.memory.content);
        let twin = kept.iter().enumerate().find_map(|(j, (o, o_sh))| duplicate_of(o, o_sh, &h, &sh, rank).map(|why| (j, why)));
        // A hit from the reserve ranked below every hit of the recall proper: it never shows a
        // higher score than the one above it.
        let h = match kept.last() {
            Some((above, _)) if i >= head && h.score > above.score => Hit { score: above.score, ..h },
            _ => h,
        };
        match twin {
            None if full => {}
            None => kept.push((h, sh)),
            Some(_) if h.exact && !full => kept.push((h, sh)),
            Some((j, why)) => {
                let other = &kept[j].0;
                if other.memory.status == MemoryStatus::Candidate && h.memory.status == MemoryStatus::Committed && !other.exact && !other.working {
                    // The confirmed record takes the candidate's place and its rank.
                    let score = other.score;
                    cut.push(ExcludedRecord {
                        id: other.memory.id,
                        reason: ExclusionReason::Duplicate,
                        detail: format!("unconfirmed; {}", why.replace(&other.memory.id.to_string(), &h.memory.id.to_string())),
                    });
                    kept[j] = (Hit { score, ..h }, sh);
                    // The candidate was not a duplicate of the hits kept beside it; its
                    // replacement may be. Those below it give way to it, those above it stay
                    // and were already compared (the twin found is the first).
                    let mut n = j + 1;
                    while n < kept.len() {
                        let (keeper, later) = (&kept[j], &kept[n]);
                        match duplicate_of(&keeper.0, &keeper.1, &later.0, &later.1, rank) {
                            Some(why) if !later.0.exact => {
                                cut.push(ExcludedRecord { id: later.0.memory.id, reason: ExclusionReason::Duplicate, detail: why });
                                kept.remove(n);
                            }
                            _ => n += 1,
                        }
                    }
                } else if !full || i < head {
                    cut.push(ExcludedRecord { id: h.memory.id, reason: ExclusionReason::Duplicate, detail: why });
                }
            }
        }
    }
    kept.into_iter().map(|(h, _)| h).collect()
}

/// The token budget as a hard cap (PERF-06): keep hits in rank order while their content fits,
/// passing over one that does not (a smaller one below it may still fit). When a block is
/// rendered, the block as a whole stays within the budget too: the lowest-ranked hits are
/// dropped until it does, and if not even the block for no memories fits, the block is empty.
/// Returns the rendered block when `format` asks for one.
pub fn pack(hits: &mut Vec<Hit>, budget: Option<usize>, format: Option<RenderFormat>, subject: &str, cut: &mut Vec<ExcludedRecord>) -> Option<String> {
    let Some(budget) = budget else {
        return format.map(|f| render(subject, hits, f));
    };
    let mut used = 0;
    hits.retain(|h| {
        let t = approx_tokens(&h.memory.content);
        if used + t <= budget {
            used += t;
            true
        } else {
            cut.push(ExcludedRecord { id: h.memory.id, reason: ExclusionReason::Budget, detail: format!("~{t} tokens do not fit the {budget}-token budget ({used} used)") });
            false
        }
    });
    let format = format?;
    loop {
        let block = render(subject, hits, format);
        let t = approx_tokens(&block);
        if t <= budget {
            return Some(block);
        }
        match hits.pop() {
            Some(h) => cut.push(ExcludedRecord {
                id: h.memory.id,
                reason: ExclusionReason::Budget,
                detail: format!("the rendered block (~{t} tokens) does not fit the {budget}-token budget"),
            }),
            None => return Some(String::new()),
        }
    }
}

/// Recall hits as one model-neutral text block (INT-04), most relevant first, in the form the
/// request picked. Every form carries each memory's id, kind, date and tags, marks a held plan
/// or guess as unconfirmed (PR-7) and the session's own notes as such.
pub fn render(subject: &str, hits: &[Hit], format: RenderFormat) -> String {
    match format {
        RenderFormat::Plain => render_plain(subject, hits),
        RenderFormat::Markdown => render_markdown(subject, hits),
        RenderFormat::Xml => render_xml(subject, hits),
    }
}

fn date(m: &Memory) -> String {
    m.occurred_at.unwrap_or(m.created_at).format("%Y-%m-%d").to_string()
}

/// The statement kind of a held candidate (`plan`, `speculation`, ...), if the hit is one.
fn unconfirmed(m: &Memory) -> Option<&str> {
    (m.status == MemoryStatus::Candidate).then(|| m.metadata.get("statement").and_then(|s| s.as_str()).unwrap_or("candidate"))
}

fn render_plain(subject: &str, hits: &[Hit]) -> String {
    if hits.is_empty() {
        return format!("No relevant memories found for {subject}.");
    }
    let lines: Vec<String> = hits
        .iter()
        .map(|h| {
            let m = &h.memory;
            let tags = if m.tags.is_empty() { String::new() } else { format!(" #{}", m.tags.join(" #")) };
            // A held plan or guess (`include_candidates`) must not read as a fact (PR-7).
            let held = unconfirmed(m).map(|s| format!(", unconfirmed {s}")).unwrap_or_default();
            // The session's own scratchpad is context, not a ranked match.
            let session = if h.working { ", this session" } else { "" };
            format!("- [{}] ({}, {}{tags}{held}{session}) {}", m.id, m.kind, date(m), m.content.replace('\n', "\n  "))
        })
        .collect();
    let noun = if hits.len() == 1 { "memory" } else { "memories" };
    format!("{} {noun} of {subject} (most relevant first):\n{}", hits.len(), lines.join("\n"))
}

fn render_markdown(subject: &str, hits: &[Hit]) -> String {
    if hits.is_empty() {
        return format!("_No relevant memories found for {subject}._");
    }
    let lines: Vec<String> = hits
        .iter()
        .enumerate()
        .map(|(i, h)| {
            let m = &h.memory;
            let tags: String = m.tags.iter().map(|t| format!(" `#{t}`")).collect();
            let held = unconfirmed(m).map(|s| format!(" · _unconfirmed {s}_")).unwrap_or_default();
            let session = if h.working { " · _this session_" } else { "" };
            format!("{}. **{}** · {}{tags}{held}{session} · `{}`\n   {}", i + 1, m.kind, date(m), m.id, m.content.replace('\n', "\n   "))
        })
        .collect();
    format!("## Memories of {subject}\n\nMost relevant first.\n\n{}", lines.join("\n"))
}

/// Escape text for an element body or a quoted attribute, so that a memory's content can never
/// close its own element or open another (the block goes into a prompt).
fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

fn render_xml(subject: &str, hits: &[Hit]) -> String {
    if hits.is_empty() {
        return format!("<memories subject=\"{}\" count=\"0\"/>", xml_escape(subject));
    }
    let lines: Vec<String> = hits
        .iter()
        .map(|h| {
            let m = &h.memory;
            let tags = if m.tags.is_empty() { String::new() } else { format!(" tags=\"{}\"", xml_escape(&m.tags.join(","))) };
            let held = unconfirmed(m).map(|s| format!(" unconfirmed=\"{}\"", xml_escape(s))).unwrap_or_default();
            let session = if h.working { " session=\"this\"" } else { "" };
            format!("<memory id=\"{}\" kind=\"{}\" date=\"{}\"{tags}{held}{session}>{}</memory>", m.id, m.kind, date(m), xml_escape(&m.content))
        })
        .collect();
    format!("<memories subject=\"{}\" count=\"{}\">\n{}\n</memories>", xml_escape(subject), hits.len(), lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use proptest::prelude::*;
    use uuid::Uuid;

    fn ranking() -> Ranking {
        crate::policy::default_policy(&Config::default(), "t").policy.ranking
    }

    fn hit(content: &str, score: f32) -> Hit {
        let memory = Memory {
            id: Uuid::new_v4(),
            tenant: "t".into(),
            subject: "s".into(),
            kind: MemoryKind::Semantic,
            status: MemoryStatus::Committed,
            content: content.into(),
            session_id: None,
            turn_ref: None,
            occurred_at: None,
            valid_from: Utc::now() - chrono::Duration::days(1000),
            valid_to: None,
            supersedes: None,
            labels: vec![],
            tags: vec![],
            source: "t".into(),
            confidence: 1.0,
            metadata: serde_json::json!({}),
            created_at: Utc::now(),
            expires_at: None,
            scope: Default::default(),
            provenance: Default::default(),
        };
        Hit { memory, score, keyword_rank: None, vector_rank: None, similarity: None, rerank_score: None, exact: false, working: false, embedding: None, features: None }
    }

    #[test]
    fn default_weights_leave_the_relevance_order_and_scores() {
        let r = ranking();
        assert!(!reorders(&r));
        let mut hits = vec![hit("a", 0.03), hit("b", 0.02), hit("c", 0.02)];
        let before: Vec<(Uuid, f32)> = hits.iter().map(|h| (h.memory.id, h.score)).collect();
        score(&mut hits, &r, Utc::now(), Utc::now());
        assert_eq!(before, hits.iter().map(|h| (h.memory.id, h.score)).collect::<Vec<_>>());
        assert!(hits.iter().all(|h| h.features.is_some()));
    }

    #[test]
    fn each_weight_moves_the_order_as_specified() {
        let now = Utc::now();
        let mut old_sure = hit("old and sure", 0.030);
        old_sure.memory.created_at = now - chrono::Duration::days(900);
        let mut new_unsure = hit("new and unsure", 0.029);
        new_unsure.memory.created_at = now;
        new_unsure.memory.confidence = 0.2;
        let mut held = hit("held plan", 0.031);
        held.memory.created_at = now - chrono::Duration::days(900);
        held.memory.status = MemoryStatus::Candidate;
        let order = |r: &Ranking| {
            let mut hits = vec![held.clone(), old_sure.clone(), new_unsure.clone()];
            score(&mut hits, r, now, now);
            hits.iter().map(|h| h.memory.content.clone()).collect::<Vec<_>>()
        };
        let base = ranking();
        assert_eq!(order(&base), ["held plan", "old and sure", "new and unsure"]);
        assert_eq!(order(&Ranking { recency_weight: 0.5, ..base.clone() })[0], "new and unsure");
        assert_eq!(order(&Ranking { confidence_weight: 0.5, validity_weight: 0.5, ..base.clone() }), ["old and sure", "held plan", "new and unsure"]);
        assert_eq!(order(&Ranking { validity_weight: 0.5, ..base.clone() }), ["old and sure", "new and unsure", "held plan"]);
        // Relevance off: confidence alone decides between the two confirmed records.
        assert_eq!(order(&Ranking { relevance_weight: 0.0, confidence_weight: 1.0, ..base })[2], "new and unsure");
    }

    #[test]
    fn validity_of_a_record_no_longer_valid_is_zero() {
        let now = Utc::now();
        let mut m = hit("x", 1.0).memory;
        assert_eq!(validity(&m, now), 1.0);
        m.valid_to = Some(now - chrono::Duration::days(1));
        assert_eq!(validity(&m, now), 0.0);
        m.valid_to = None;
        m.expires_at = Some(now - chrono::Duration::seconds(1));
        assert_eq!(validity(&m, now), 0.0);
    }

    #[test]
    fn overlap_and_cosine() {
        let a = shingles("The customer prefers email over phone calls.");
        assert_eq!(overlap(&a, &shingles("the customer prefers EMAIL over phone calls")), 1.0);
        assert!(overlap(&a, &shingles("The customer prefers a phone call in the morning")) < 0.5);
        assert_eq!(overlap(&shingles(""), &shingles("")), 0.0);
        assert_eq!(overlap(&shingles("Berlin"), &shingles("berlin")), 1.0);
        assert!((cosine(&[1.0, 0.0], &[2.0, 0.0]) - 1.0).abs() < 1e-6);
        assert_eq!(cosine(&[1.0, 0.0], &[0.0, 1.0]), 0.0);
        assert_eq!(cosine(&[1.0], &[1.0, 2.0]), 0.0);
    }

    #[test]
    fn duplicates_are_removed_and_their_places_refilled() {
        let r = Ranking { dedup: true, dedup_cosine: 0.95, dedup_overlap: 0.85, ..ranking() };
        let mut a = hit("Dana moved to Berlin in March 2024.", 0.5);
        a.embedding = Some(vec![1.0, 0.0, 0.0]);
        let mut same_vector = hit("In March of 2024 Dana relocated to Berlin, Germany.", 0.4);
        same_vector.embedding = Some(vec![0.99, 0.05, 0.0]);
        let same_text = hit("dana moved to berlin in march 2024", 0.3);
        let mut other = hit("Dana works at Acme as a designer.", 0.2);
        other.embedding = Some(vec![0.0, 1.0, 0.0]);
        let spare = hit("Dana has a dog called Rex.", 0.1);
        let unused = hit("Dana likes tea.", 0.05);
        let mut cut = vec![];
        let out = dedup(vec![a.clone(), same_vector.clone(), same_text.clone(), other.clone()], vec![spare.clone(), unused.clone()], 3, &r, &mut cut);
        // Two duplicates freed two places; k = 3 leaves one for the reserve's first.
        assert_eq!(out.iter().map(|h| h.memory.id).collect::<Vec<_>>(), [a.memory.id, other.memory.id, spare.memory.id]);
        assert_eq!(
            cut.iter().map(|c| (c.id, c.reason)).collect::<Vec<_>>(),
            [(same_vector.memory.id, ExclusionReason::Duplicate), (same_text.memory.id, ExclusionReason::Duplicate)]
        );
        assert!(cut[0].detail.starts_with("cosine") && cut[1].detail.starts_with("text overlap") && !cut[0].detail.contains("Berlin"));
        // Off: nothing is removed and the reserve is not used.
        let off = dedup(vec![a.clone(), same_text.clone()], vec![spare], 3, &Ranking { dedup: false, ..r.clone() }, &mut vec![]);
        assert_eq!(off.len(), 2);
        // Nothing removed: the reserve stays out, whatever k is.
        assert_eq!(dedup(vec![a.clone(), other.clone()], vec![unused], 10, &r, &mut vec![]).len(), 2);
    }

    #[test]
    fn a_confirmed_record_replaces_its_unconfirmed_twin_and_an_exact_match_stays() {
        let r = Ranking { dedup: true, dedup_cosine: 0.95, dedup_overlap: 0.85, ..ranking() };
        let mut held = hit("Dana will move to Berlin next year.", 0.9);
        held.memory.status = MemoryStatus::Candidate;
        let confirmed = hit("Dana will move to Berlin next year", 0.1);
        let mut cut = vec![];
        let out = dedup(vec![held.clone(), confirmed.clone()], vec![], 5, &r, &mut cut);
        assert_eq!((out.len(), out[0].memory.id, out[0].score), (1, confirmed.memory.id, 0.9));
        assert_eq!(cut[0].id, held.memory.id);
        let mut exact = hit("Dana will move to Berlin next year", 0.1);
        exact.exact = true;
        assert_eq!(dedup(vec![confirmed, exact], vec![], 5, &r, &mut vec![]).len(), 2);
    }

    #[test]
    fn the_same_words_in_two_sessions_are_two_events() {
        let r = Ranking { dedup: true, dedup_cosine: 0.95, dedup_overlap: 0.85, ..ranking() };
        let said = |session: &str| {
            let mut h = hit("We reviewed the Globex pricing proposal with their finance team.", 0.5);
            h.memory.kind = MemoryKind::Episodic;
            h.memory.session_id = Some(session.into());
            h
        };
        assert_eq!(dedup(vec![said("march"), said("august")], vec![], 5, &r, &mut vec![]).len(), 2);
        assert_eq!(dedup(vec![said("march"), said("march")], vec![], 5, &r, &mut vec![]).len(), 1);
        // A fact that repeats a round is still its duplicate.
        assert_eq!(dedup(vec![said("march"), hit("We reviewed the Globex pricing proposal with their finance team.", 0.4)], vec![], 5, &r, &mut vec![]).len(), 1);
    }

    #[test]
    fn a_confirmed_twin_in_the_reserve_replaces_a_kept_candidate_without_taking_a_place() {
        let r = Ranking { dedup: true, dedup_cosine: 0.97, dedup_overlap: 0.9, ..ranking() };
        let mut held = hit("Dana will move to Berlin next year.", 0.9);
        held.memory.status = MemoryStatus::Candidate;
        let confirmed = hit("Dana will move to Berlin next year", 0.2);
        let unrelated = hit("Rex is the dog", 0.3);
        let out = dedup(vec![held.clone()], vec![unrelated, confirmed.clone()], 1, &r, &mut vec![]);
        assert_eq!(out.iter().map(|h| h.memory.id).collect::<Vec<_>>(), [confirmed.memory.id]);
    }

    #[test]
    fn a_replacement_is_compared_with_the_hits_kept_beside_the_candidate() {
        let r = Ranking { dedup: true, dedup_cosine: 0.97, dedup_overlap: 0.9, ..ranking() };
        let with = |text: &str, v: [f32; 2], score: f32| {
            let mut h = hit(text, score);
            h.embedding = Some(v.to_vec());
            h
        };
        let mut a = with("alpha one two three", [1.0, 0.0], 0.9);
        a.memory.status = MemoryStatus::Candidate;
        let b = with("bravo four five six", [0.96, 0.28], 0.8);
        let c = with("charlie seven eight nine", [0.99, 0.14], 0.7);
        let mut cut = vec![];
        let out = dedup(vec![a.clone(), b.clone(), c.clone()], vec![], 5, &r, &mut cut);
        // C replaces its unconfirmed twin A; B, a duplicate of C but not of A, gives way.
        assert_eq!(out.iter().map(|h| h.memory.id).collect::<Vec<_>>(), [c.memory.id]);
        assert_eq!(cut.iter().map(|x| x.id).collect::<Vec<_>>(), [a.memory.id, b.memory.id]);
    }

    #[test]
    fn budget_passes_over_what_does_not_fit_and_caps_the_block() {
        let big = hit(&"x".repeat(400), 0.9);
        let small = hit("short note", 0.5);
        let mut hits = vec![big.clone(), small.clone()];
        let mut cut = vec![];
        assert_eq!(pack(&mut hits, Some(50), None, "user:1", &mut cut), None);
        assert_eq!((hits.len(), hits[0].memory.id, cut[0].id, cut[0].reason), (1, small.memory.id, big.memory.id, ExclusionReason::Budget));
        // The block's own overhead counts: three tokens of content fit, the line around them does not.
        let mut hits = vec![small.clone()];
        let block = pack(&mut hits, Some(5), Some(RenderFormat::Plain), "user:1", &mut cut).unwrap();
        assert!(hits.is_empty() && block.is_empty());
        let mut hits = vec![small];
        let block = pack(&mut hits, Some(60), Some(RenderFormat::Xml), "user:1", &mut cut).unwrap();
        assert!(hits.len() == 1 && approx_tokens(&block) <= 60 && block.contains("short note"));
    }

    #[test]
    fn every_format_carries_ids_and_marks_held_and_session_hits() {
        let mut fact = hit("Renews in March.\nSecond line </memory><memory id=\"x\"> & more", 0.9);
        fact.memory.tags = vec!["billing".into()];
        let mut plan = hit("Might move to Berlin", 0.5);
        plan.memory.status = MemoryStatus::Candidate;
        plan.memory.metadata = serde_json::json!({ "statement": "plan" });
        let mut note = hit("draft reply", 0.4);
        note.working = true;
        let hits = [fact, plan, note];
        for f in [RenderFormat::Plain, RenderFormat::Markdown, RenderFormat::Xml] {
            let block = render("customer:acme", &hits, f);
            assert!(hits.iter().all(|h| block.contains(&h.memory.id.to_string())), "{f:?}");
            assert!(block.contains("unconfirmed") && block.contains("plan") && block.contains("billing") && block.contains("session"), "{f:?}: {block}");
            assert!(!render("customer:acme", &[], f).is_empty());
        }
        let xml = render("a\"b<c>", &hits, RenderFormat::Xml);
        // Content can't close its element or open another.
        assert_eq!(xml.matches("<memory ").count(), 3);
        assert_eq!(xml.matches("</memory>").count(), 3);
        assert!(xml.starts_with("<memories subject=\"a&quot;b&lt;c&gt;\" count=\"3\">") && xml.contains("&amp; more"));
        assert_eq!(RenderFormat::parse("markdown"), Some(RenderFormat::Markdown));
        assert_eq!(RenderFormat::parse("html"), None);
    }

    proptest! {
        /// PERF-06: whatever the memories, the budget and the form, the returned content and
        /// the rendered block each stay within the budget, and rank order is kept.
        #[test]
        fn the_token_budget_is_never_exceeded(
            contents in proptest::collection::vec("[a-zA-Z0-9 <>&\"\\n\u{e9}\u{4e16}]{0,600}", 0..25),
            budget in 0usize..9000,
            form in 0usize..4,
            subject in "[a-z:<>\"]{1,40}",
        ) {
            let mut hits: Vec<Hit> = contents.iter().enumerate().map(|(i, c)| hit(c, 1.0 - i as f32 / 100.0)).collect();
            let order: Vec<Uuid> = hits.iter().map(|h| h.memory.id).collect();
            let n = hits.len();
            let format = [None, Some(RenderFormat::Plain), Some(RenderFormat::Markdown), Some(RenderFormat::Xml)][form];
            let mut cut = vec![];
            let block = pack(&mut hits, Some(budget), format, &subject, &mut cut);
            let used: usize = hits.iter().map(|h| approx_tokens(&h.memory.content)).sum();
            prop_assert!(used <= budget, "content {used} > {budget}");
            prop_assert_eq!(block.is_some(), format.is_some());
            if let Some(b) = &block {
                prop_assert!(approx_tokens(b) <= budget, "block {} > {budget}", approx_tokens(b));
                prop_assert!(hits.iter().all(|h| b.contains(&h.memory.id.to_string())));
            }
            prop_assert_eq!(hits.len() + cut.len(), n);
            let kept: Vec<Uuid> = order.iter().copied().filter(|id| hits.iter().any(|h| h.memory.id == *id)).collect();
            prop_assert_eq!(kept, hits.iter().map(|h| h.memory.id).collect::<Vec<_>>());
        }

        /// ECON-03: after removal no two returned memories reach either threshold.
        #[test]
        fn no_two_kept_hits_reach_a_threshold(
            picks in proptest::collection::vec((0usize..6, 0usize..4), 1..30),
            k in 1usize..20,
        ) {
            let texts = ["Dana moved to Berlin in March 2024", "dana moved to berlin in march 2024!", "Acme renews its contract in June", "The gym locker code is 4417", "Acme renews its contract in June.", "Rex is the dog"];
            let vectors = [vec![1.0, 0.0, 0.0], vec![0.96, 0.28, 0.0], vec![0.99, 0.14, 0.0], vec![0.0, 0.0, 1.0]];
            let r = Ranking { dedup: true, dedup_cosine: 0.97, dedup_overlap: 0.85, ..ranking() };
            // Every third hit is a candidate, so a confirmed twin replaces some of them.
            let all: Vec<Hit> = picks
                .iter()
                .enumerate()
                .map(|(i, (t, v))| {
                    let mut h = hit(texts[*t], 1.0 - i as f32 / 100.0);
                    h.embedding = Some(vectors[*v].clone());
                    if (t + v + i) % 3 == 0 {
                        h.memory.status = MemoryStatus::Candidate;
                    }
                    h
                })
                .collect();
            let split = all.len().min(k);
            let (head, reserve) = (all[..split].to_vec(), all[split..].to_vec());
            let out = dedup(head, reserve, k, &r, &mut vec![]);
            prop_assert!(out.len() <= k);
            for (i, a) in out.iter().enumerate() {
                for b in &out[i + 1..] {
                    prop_assert!(cosine(a.embedding.as_ref().unwrap(), b.embedding.as_ref().unwrap()) < r.dedup_cosine);
                    prop_assert!(overlap(&shingles(&a.memory.content), &shingles(&b.memory.content)) < r.dedup_overlap);
                }
            }
        }
    }
}
