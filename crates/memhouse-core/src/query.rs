// SPDX-License-Identifier: Apache-2.0
//! Query analysis without an LLM: time windows ("two weeks ago", "last Saturday", "in February",
//! "the past three months") resolved against the time of the question, and sub-queries for
//! questions that compare or combine several things ("A or B", "between A and B", quoted titles,
//! "... when ..." clauses). The phrases are data: they come from the language pack of the
//! question ([`crate::lang`]). Recall runs one extra probe restricted to the windows and fuses it with
//! the main query. Sub-query probes are available but off by default (`memory.subquery_weight`):
//! on LongMemEval they found the second event no better than BM25 plus the user-only vector.

use crate::lang::{Detected, Pack, Unit};
use chrono::{DateTime, Datelike, Duration, Months, NaiveDate, TimeZone, Utc, Weekday};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TimeWindow {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// The phrase the window was read from.
    pub phrase: String,
    /// What the phrase resolves to, for people and answer models ("2023-04-15 (Sat)").
    #[serde(default)]
    pub meaning: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct QueryPlan {
    pub windows: Vec<TimeWindow>,
    pub subqueries: Vec<String>,
    /// Identifiers in the question ("A-1001", "#4521") looked up exactly in structured records
    /// (HYB-03): the plan then mixes keyword, vector and exact retrieval.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub exact: Vec<String>,
}

/// The plan of a question in one language.
pub fn analyze(pack: &Pack, text: &str, now: DateTime<Utc>) -> QueryPlan {
    QueryPlan { windows: time_windows(pack, text, now), subqueries: subqueries(pack, text), exact: vec![] }
}

/// The plan of a question whose language was detected (or not): the detected pack's reading,
/// and, when the detection was not sure, the time windows any other enabled pack finds too.
pub fn analyze_detected(lang: &Detected, text: &str, now: DateTime<Utc>) -> QueryPlan {
    let mut plan = analyze(&lang.pack, text, now);
    for other in &lang.others {
        for w in time_windows(other, text, now) {
            if !plan.windows.iter().any(|x| x.start == w.start && x.end == w.end) {
                plan.windows.push(w);
            }
        }
        if plan.subqueries.is_empty() {
            plan.subqueries = subqueries(other, text);
        }
    }
    plan
}

// Letters of any script: an identifier may start with "Č" or "Ж" as well as "A".
static IDENT: Lazy<Regex> = Lazy::new(|| Regex::new(r"#?\b\p{L}{0,12}[-_/]?\d[\w\-/]*\b|\b\p{L}+\d[\w\-]*\b").expect("valid regex"));

/// Record identifiers in a question, for the exact probe: tokens with a digit that are not dates,
/// years, times, ordinals, amounts with a unit, or short numbers (plain numbers need 5 digits).
pub fn identifiers(pack: &Pack, text: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for m in IDENT.find_iter(text) {
        let t = m.as_str().trim_start_matches('#').trim_matches(|c: char| c == '-' || c == '/' || c == '_');
        let lower = t.to_lowercase();
        let has_alpha = t.chars().any(|c| c.is_alphabetic());
        let digits = t.chars().filter(|c| c.is_ascii_digit()).count();
        let len = t.chars().count();
        // A `#` marks an identifier however short ("#77"); otherwise at least three characters.
        let hashed = m.as_str().starts_with('#');
        let date_like = pack.time.date_like.as_ref().is_some_and(|re| re.is_match(&lower));
        let ok = (len >= 3 || (hashed && len >= 2)) && !date_like && (has_alpha || digits >= 5 || hashed);
        if ok && !out.contains(&lower) {
            out.push(lower);
        }
        if out.len() >= 5 {
            break;
        }
    }
    out
}

fn day_start(d: NaiveDate) -> DateTime<Utc> {
    Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap())
}

fn back(now: DateTime<Utc>, n: i64, unit: Unit) -> DateTime<Utc> {
    match unit {
        Unit::Day => now - Duration::days(n),
        Unit::Week => now - Duration::weeks(n),
        Unit::Month => now.checked_sub_months(Months::new(n.clamp(0, 1200) as u32)).unwrap_or(now),
        Unit::Year => now.checked_sub_months(Months::new((n * 12).clamp(0, 1200) as u32)).unwrap_or(now),
    }
}

fn unit_days(unit: Unit) -> f64 {
    match unit {
        Unit::Day => 1.0,
        Unit::Week => 7.0,
        Unit::Month => 30.0,
        Unit::Year => 365.0,
    }
}

/// The most recent occurrence of `month` that starts on or before `now`.
fn month_range(month: u32, now: DateTime<Utc>) -> (DateTime<Utc>, DateTime<Utc>) {
    let mut year = now.year();
    if month > now.month() {
        year -= 1;
    }
    let start = NaiveDate::from_ymd_opt(year, month, 1).unwrap();
    let end = start.checked_add_months(Months::new(1)).unwrap();
    (day_start(start), day_start(end))
}

static ISO_DATE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b").unwrap());

/// Time windows mentioned in `text`, relative to `now`, read with the time phrases of `pack`.
/// Windows are deliberately generous: people say "two weeks ago" for anything from ten days to
/// three weeks, and the conversation that mentions an event usually comes a little after it.
pub fn time_windows(pack: &Pack, text: &str, now: DateTime<Utc>) -> Vec<TimeWindow> {
    let t = text.to_lowercase();
    let r = &pack.time;
    let mut out: Vec<TimeWindow> = vec![];
    let fmt = |d: NaiveDate| d.format("%Y-%m-%d (%a)").to_string();
    let mut push = |start: DateTime<Utc>, end: DateTime<Utc>, phrase: &str, meaning: String| {
        if start < end && !out.iter().any(|w| w.start == start && w.end == end) {
            out.push(TimeWindow { start, end, phrase: phrase.to_string(), meaning });
        }
    };
    if let Some(tp) = &r.ago {
        for c in tp.re.captures_iter(&t) {
            let (Some(n), Some(unit)) = (tp.get(&c, 'n').and_then(|s| r.num(s)), tp.get(&c, 'u').and_then(|s| r.unit(s))) else { continue };
            let centre = back(now, n, unit);
            let slack_days = (n as f64 * unit_days(unit) * 0.35).max(if unit == Unit::Day { 1.5 } else { 4.0 });
            let slack = Duration::seconds((slack_days * 86_400.0) as i64);
            push(centre - slack, (centre + slack).min(now + Duration::days(1)), &c[0], format!("about {}", fmt(centre.date_naive())));
        }
    }
    if let Some(tp) = &r.past {
        for c in tp.re.captures_iter(&t) {
            let Some(unit) = tp.get(&c, 'u').and_then(|s| r.unit(s)) else { continue };
            let stated = tp.get(&c, 'n');
            let n = stated.and_then(|s| r.num(s)).unwrap_or(1);
            // "last month" / "last year" also mean the previous calendar period.
            if stated.is_none() && r.calendar.as_ref().is_some_and(|re| re.is_match(&c[0])) && (unit == Unit::Month || unit == Unit::Year) {
                let today = now.date_naive();
                let (s, e) = if unit == Unit::Month {
                    let first = today.with_day(1).unwrap();
                    (first.checked_sub_months(Months::new(1)).unwrap(), first)
                } else {
                    (NaiveDate::from_ymd_opt(today.year() - 1, 1, 1).unwrap(), NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap())
                };
                let pad = Duration::days(if unit == Unit::Month { 7 } else { 30 });
                let meaning = if unit == Unit::Month { s.format("%B %Y").to_string() } else { s.format("%Y").to_string() };
                push(day_start(s) - pad, (day_start(e) + pad).min(now + Duration::days(1)), &c[0], meaning);
                continue;
            }
            let pad = Duration::days(if unit == Unit::Day { 1 } else { 3 });
            push(back(now, n, unit) - pad, now + Duration::days(1), &c[0], format!("since {}", fmt(back(now, n, unit).date_naive())));
        }
    }
    if let Some(tp) = &r.last_weekday {
        for c in tp.re.captures_iter(&t) {
            let Some(wd) = tp.get(&c, 'w').and_then(|s| r.weekday(s)) else { continue };
            let today = now.date_naive();
            let mut d = today - Duration::days(1);
            while d.weekday() != wd {
                d -= Duration::days(1);
            }
            // "this Saturday" asked on a Saturday may mean today.
            let strictly_before = r.strictly_before.as_ref().is_some_and(|re| re.is_match(&c[0]));
            if !strictly_before && today.weekday() == wd {
                d = today;
            }
            push(day_start(d) - Duration::days(1), day_start(d) + Duration::days(3), &c[0], fmt(d));
        }
    }
    if let Some(tp) = &r.last_weekend {
        for c in tp.re.captures_iter(&t) {
            let mut d = now.date_naive() - Duration::days(1);
            while d.weekday() != Weekday::Sat {
                d -= Duration::days(1);
            }
            push(day_start(d) - Duration::days(1), day_start(d) + Duration::days(4), &c[0], format!("{} to {}", fmt(d), fmt(d + Duration::days(1))));
        }
    }
    if let Some(tp) = &r.yesterday {
        for c in tp.re.captures_iter(&t) {
            let d = now.date_naive() - Duration::days(1);
            push(day_start(d) - Duration::days(1), now + Duration::days(1), &c[0], fmt(d));
        }
    }
    if let Some(tp) = &r.this {
        for c in tp.re.captures_iter(&t) {
            let today = now.date_naive();
            let s = match tp.get(&c, 'u').and_then(|s| r.unit(s)) {
                Some(Unit::Week) => today - Duration::days(today.weekday().num_days_from_monday() as i64),
                Some(Unit::Month) => today.with_day(1).unwrap(),
                Some(Unit::Year) => NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap(),
                // "this day" is today: no window worth a probe.
                _ => continue,
            };
            push(day_start(s) - Duration::days(2), now + Duration::days(1), &c[0], format!("since {}", fmt(s)));
        }
    }
    if let Some(tp) = &r.in_month {
        for c in tp.re.captures_iter(&t) {
            let Some(m) = tp.get(&c, 'm').and_then(|s| r.month(s)) else { continue };
            let (s, e) = month_range(m, now);
            let day = tp.get(&c, 'd').and_then(|d| d.parse::<u32>().ok()).filter(|d| (1..=31).contains(d));
            match day.and_then(|d| NaiveDate::from_ymd_opt(s.year(), m, d)) {
                Some(d) => push(day_start(d) - Duration::days(2), day_start(d) + Duration::days(5), &c[0], fmt(d)),
                None => push(s - Duration::days(3), e + Duration::days(7), &c[0], s.format("%B %Y").to_string()),
            }
        }
    }
    for c in ISO_DATE.captures_iter(&t) {
        if let Some(d) = NaiveDate::from_ymd_opt(c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0), c[3].parse().unwrap_or(0)) {
            push(day_start(d) - Duration::days(2), day_start(d) + Duration::days(5), &c[0], fmt(d));
        }
    }
    out
}

static QUOTED: Lazy<Regex> = Lazy::new(|| Regex::new(r#"(?:^|[\s(])['"‘“„«]([^'"‘’“”„«»]{3,80})['"’”“»](?:[\s,.?!:;)]|$)"#).unwrap());

fn clean(pack: &Pack, s: &str) -> String {
    let s = s.trim().trim_matches(|c: char| c == '?' || c == '.' || c == '!' || c == ',' || c.is_whitespace());
    match &pack.query.article {
        Some(re) => re.replace(s, "").trim().to_string(),
        None => s.to_string(),
    }
}

fn words(s: &str) -> usize {
    s.split_whitespace().count()
}

/// Sub-queries for questions about several things at once. Empty for ordinary questions.
pub fn subqueries(pack: &Pack, text: &str) -> Vec<String> {
    let r = &pack.query;
    let mut out: Vec<String> = vec![];
    let mut push = |s: String| {
        if words(&s) >= 1 && s.len() >= 3 && !out.iter().any(|o| o.eq_ignore_ascii_case(&s)) && out.len() < 4 {
            out.push(s);
        }
    };
    let lead = |s: &str| match &r.lead {
        Some(re) => re.replace(s, "").to_string(),
        None => s.to_string(),
    };
    let alternatives = |s: &str| -> Vec<String> {
        match &r.or {
            Some(re) => re.split(s).map(String::from).collect(),
            None => vec![s.to_string()],
        }
    };
    let q = text.trim();
    for c in QUOTED.captures_iter(q) {
        push(c[1].trim().to_string());
    }
    let has_or = r.or.as_ref().is_some_and(|re| re.is_match(q));
    let or_not = r.or_not.iter().any(|p| q.contains(&format!(" {p}")));
    // "Which X did I do first, the A or the B?"
    if let Some((head, tail)) = q.rsplit_once(',') {
        let alts = alternatives(tail);
        if alts.len() >= 2 {
            let head = lead(head.trim());
            for a in alts {
                let a = clean(pack, &a);
                if !a.is_empty() {
                    push(format!("{head} {a}"));
                }
            }
        }
    } else if has_or && !or_not {
        // "Did I buy the A or the B first?"
        let parts = alternatives(&lead(q));
        if parts.len() == 2 && words(&parts[0]) <= 12 && words(&parts[1]) <= 12 {
            push(clean(pack, &parts[0]));
            push(clean(pack, &parts[1]));
        }
    }
    if let Some(c) = r.between.iter().find_map(|re| re.captures(q)) {
        push(clean(pack, &c[1]));
        push(clean(pack, &c[2]));
    }
    // "How long had I been a member of X when I attended the meetup?"
    if let Some(clause) = &r.clause {
        let parts: Vec<&str> = clause.split(q).collect();
        if parts.len() == 2 && words(parts[0]) >= 3 && words(parts[1]) >= 3 {
            push(clean(pack, &lead(parts[0])));
            push(clean(pack, parts[1]));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn en() -> std::sync::Arc<Pack> {
        crate::lang::Languages::english().default_pack().clone()
    }

    fn identifiers(text: &str) -> Vec<String> {
        super::identifiers(&en(), text)
    }

    fn time_windows(text: &str, now: DateTime<Utc>) -> Vec<TimeWindow> {
        super::time_windows(&en(), text, now)
    }

    fn subqueries(text: &str) -> Vec<String> {
        super::subqueries(&en(), text)
    }

    #[test]
    fn finds_record_identifiers_not_dates() {
        assert_eq!(identifiers("What is the status of order A-1001?"), vec!["a-1001"]);
        assert_eq!(identifiers("ticket #4521 and invoice INV2024-77"), vec!["4521", "inv2024-77"]);
        assert_eq!(identifiers("customer 1234567"), vec!["1234567"]);
        assert_eq!(identifiers("What happened to ticket #77?"), vec!["77"]);
        assert!(identifiers("What did I do on 2023-05-01 at 3pm, 2 days after the 1st?").is_empty());
        assert!(identifiers("How many of the 12 books did I read in 2023?").is_empty());
        assert!(identifiers("I paid $40 for 3kg of rice").is_empty());
    }

    fn at(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn covers(ws: &[TimeWindow], t: &str) -> bool {
        let t = at(t);
        ws.iter().any(|w| w.start <= t && t < w.end)
    }

    #[test]
    fn relative_windows() {
        let now = at("2023-07-01T13:38:00Z"); // a Saturday
        let w = time_windows("I mentioned participating in a sports event two weeks ago.", now);
        assert!(covers(&w, "2023-06-17T15:20:00Z") && !covers(&w, "2023-05-20T00:00:00Z"));
        let w = time_windows("the three sports events during the past month", now);
        assert!(covers(&w, "2023-06-02T15:29:00Z") && !covers(&w, "2023-04-15T00:00:00Z"));
        let w = time_windows("Who did I go with to the music event last Saturday?", at("2023-04-22T08:01:00Z"));
        assert!(covers(&w, "2023-04-15T03:11:00Z") && !covers(&w, "2023-04-01T15:57:00Z"));
        let w = time_windows("What was the date of the first BBQ event in June?", now);
        assert!(covers(&w, "2023-06-03T12:00:00Z") && !covers(&w, "2023-05-01T00:00:00Z"));
        let w = time_windows("Which pair of shoes did I clean last month?", at("2023-05-30T01:50:00Z"));
        assert!(covers(&w, "2023-04-20T00:00:00Z") && !covers(&w, "2023-02-10T00:00:00Z"));
        let w = time_windows("Which vehicle did I take care of first in February?", at("2023-03-10T23:15:00Z"));
        assert!(covers(&w, "2023-02-14T00:00:00Z"));
        assert!(time_windows("May I ask what my dog's name is?", now).is_empty());
        assert!(time_windows("What is my favourite colour?", now).is_empty());
    }

    #[test]
    fn comparisons_split() {
        let s = subqueries("Which device did I set up first, the smart thermostat or the new router?");
        assert_eq!(s, vec!["device did I set up first smart thermostat", "device did I set up first new router"]);
        let s = subqueries("How many days had passed between the Hindu festival of Holi and the Sunday mass at St. Mary's Church?");
        assert!(s.contains(&"Hindu festival of Holi".to_string()) && s.contains(&"Sunday mass at St. Mary's Church".to_string()));
        let s = subqueries("How long did I take to finish 'The Seven Husbands of Evelyn Hugo' and 'The Nightingale' combined?");
        assert!(s.contains(&"The Seven Husbands of Evelyn Hugo".to_string()) && s.contains(&"The Nightingale".to_string()));
        let s = subqueries("How long had I been a member of 'Book Lovers Unite' when I attended the meetup?");
        assert!(s.iter().any(|x| x.contains("attended the meetup")));
        assert!(subqueries("What is my dog's name?").is_empty());
        assert!(subqueries("I've been thinking, what's a good gift for my sister?").is_empty());
    }
}
