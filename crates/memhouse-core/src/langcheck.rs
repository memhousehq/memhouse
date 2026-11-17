// SPDX-License-Identifier: Apache-2.0
//! A language pack's labelled test set, checked without a store: the statements the gate must
//! read as labelled, the injection attempts it must quarantine, and the questions whose time
//! phrases and identifiers must be read. The test set is an evaluation suite (`docs/evaluation.md`)
//! whose turns carry `statement` and `injection` labels and whose questions carry `covers` and
//! `ids`, so the same file can also be replayed end to end (`memhouse bench run --suite`).

use crate::eval::Suite;
use crate::lang::{Languages, Pack};
use crate::types::{MemoryKind, Statement};
use chrono::{TimeZone, Utc};
use serde::Serialize;

/// The share of labelled statements a pack must read correctly.
pub const MIN_STATEMENT_ACCURACY: f64 = 0.95;

/// How a pack did on its test set.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Report {
    pub language: String,
    pub statements: usize,
    pub statements_right: usize,
    /// Plans and guesses read as something the gate commits.
    pub held_committed: usize,
    pub injections: usize,
    pub injections_caught: usize,
    /// Labelled statements the injection screen would quarantine.
    pub false_alarms: usize,
    pub time_questions: usize,
    pub time_right: usize,
    pub id_questions: usize,
    pub ids_right: usize,
    /// One line for each item that went wrong.
    pub failures: Vec<String>,
}

impl Report {
    pub fn accuracy(&self) -> f64 {
        if self.statements == 0 {
            0.0
        } else {
            self.statements_right as f64 / self.statements as f64
        }
    }

    /// The bar every built-in pack clears: 95% of the labelled statements read correctly, no
    /// plan or guess read as something to commit, every injection attempt caught, no statement
    /// quarantined by mistake, and every labelled question read.
    pub fn passes(&self) -> bool {
        self.statements > 0
            && self.accuracy() >= MIN_STATEMENT_ACCURACY
            && self.held_committed == 0
            && self.injections > 0
            && self.injections_caught == self.injections
            && self.false_alarms == 0
            && self.time_right == self.time_questions
            && self.ids_right == self.id_questions
    }

    pub fn summary(&self) -> String {
        format!(
            "{}: statements {}/{} ({:.1}%), plans or guesses read as committed {}, injections caught {}/{}, false alarms {}, time questions {}/{}, identifier questions {}/{}",
            self.language,
            self.statements_right,
            self.statements,
            self.accuracy() * 100.0,
            self.held_committed,
            self.injections_caught,
            self.injections,
            self.false_alarms,
            self.time_right,
            self.time_questions,
            self.ids_right,
            self.id_questions
        )
    }
}

/// Check `pack` against its test set. `languages` supplies the injection screen as a server
/// runs it (the pack's phrases, every other enabled pack's, and the English floor).
pub fn check(languages: &Languages, pack: &Pack, suite: &Suite) -> Report {
    let mut r = Report { language: pack.code().to_string(), ..Default::default() };
    for c in &suite.conversations {
        for session in &c.sessions {
            for turn in &session.turns {
                let reasons = languages.injection(&turn.say);
                if turn.injection {
                    r.injections += 1;
                    if reasons.is_empty() {
                        r.failures.push(format!("injection not caught: {:?}", turn.say));
                    } else {
                        r.injections_caught += 1;
                    }
                    continue;
                }
                let Some(label) = turn.statement else { continue };
                r.statements += 1;
                if !reasons.is_empty() {
                    r.false_alarms += 1;
                    r.failures.push(format!("quarantined by mistake ({}): {:?}", reasons.join(", "), turn.say));
                }
                let read = pack.classify_text(&turn.say, turn.kind.unwrap_or(MemoryKind::Semantic));
                if read.statement == label {
                    r.statements_right += 1;
                } else {
                    if label.held() && !read.statement.held() {
                        r.held_committed += 1;
                    }
                    r.failures.push(format!("{} read as {} ({}): {:?}", label.as_str(), read.statement.as_str(), read.reason, turn.say));
                }
            }
            for q in &session.ask {
                if !q.covers.is_empty() {
                    r.time_questions += 1;
                    let now = session.at.unwrap_or_else(Utc::now);
                    let windows = crate::query::time_windows(pack, &q.q, now);
                    let missed: Vec<String> = q
                        .covers
                        .iter()
                        .filter(|d| {
                            let noon = Utc.from_utc_datetime(&d.and_hms_opt(12, 0, 0).expect("noon"));
                            !windows.iter().any(|w| w.start <= noon && noon < w.end)
                        })
                        .map(|d| d.to_string())
                        .collect();
                    if missed.is_empty() {
                        r.time_right += 1;
                    } else {
                        let read: Vec<&str> = windows.iter().map(|w| w.phrase.as_str()).collect();
                        r.failures.push(format!("time phrase not read (missed {}; read {:?}): {:?}", missed.join(", "), read, q.q));
                    }
                }
                if !q.ids.is_empty() {
                    r.id_questions += 1;
                    let found = crate::query::identifiers(pack, &q.q);
                    let want: Vec<String> = q.ids.iter().map(|i| i.to_lowercase()).collect();
                    if found == want {
                        r.ids_right += 1;
                    } else {
                        r.failures.push(format!("identifiers read as {found:?}, not {want:?}: {:?}", q.q));
                    }
                }
            }
        }
    }
    r
}

/// The statement types a test set has no example of: a set should label each of the seven.
pub fn missing_types(suite: &Suite) -> Vec<Statement> {
    let seen: Vec<Statement> = suite.conversations.iter().flat_map(|c| &c.sessions).flat_map(|s| &s.turns).filter_map(|t| t.statement).collect();
    Statement::ALL.into_iter().filter(|s| !seen.contains(s)).collect()
}
