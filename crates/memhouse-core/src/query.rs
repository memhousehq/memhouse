// SPDX-License-Identifier: Apache-2.0
//! Query analysis without an LLM: time windows ("two weeks ago", "last Saturday", "in February",
//! "the past three months") resolved against the time of the question, and sub-queries for
//! questions that compare or combine several things ("A or B", "between A and B", quoted titles,
//! "... when ..." clauses). Recall runs one extra probe restricted to the windows and fuses it with
//! the main query. Sub-query probes are available but off by default (`memory.subquery_weight`):
//! on LongMemEval they found the second event no better than BM25 plus the user-only vector.

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

pub fn analyze(text: &str, now: DateTime<Utc>) -> QueryPlan {
    QueryPlan { windows: time_windows(text, now), subqueries: subqueries(text), exact: vec![] }
}

static IDENT: Lazy<Regex> = Lazy::new(|| Regex::new(r"#?\b[A-Za-z]{0,12}[-_/]?\d[\w\-/]*\b|\b[A-Za-z]+\d[\w\-]*\b").expect("valid regex"));
static DATE_LIKE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^(?:(?:19|20)\d{2}(?:[-/]\d{1,2}){0,2}|\d{1,2}[-/]\d{1,2}(?:[-/]\d{2,4})?|\d{1,2}(?:st|nd|rd|th|am|pm|s)|\d+(?:k|m|h|d|y|kg|km|mi|min|ms|gb|mb|x|%))$")
        .expect("valid regex")
});

/// Record identifiers in a question, for the exact probe: tokens with a digit that are not dates,
/// years, times, ordinals, amounts with a unit, or short numbers (plain numbers need 5 digits).
pub fn identifiers(text: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for m in IDENT.find_iter(text) {
        let t = m.as_str().trim_start_matches('#').trim_matches(|c: char| c == '-' || c == '/' || c == '_');
        let lower = t.to_lowercase();
        let has_alpha = t.chars().any(|c| c.is_ascii_alphabetic());
        let digits = t.chars().filter(|c| c.is_ascii_digit()).count();
        // A `#` marks an identifier however short ("#77"); otherwise at least three characters.
        let hashed = m.as_str().starts_with('#');
        let ok = (t.len() >= 3 || (hashed && t.len() >= 2)) && !DATE_LIKE.is_match(&lower) && (has_alpha || digits >= 5 || hashed);
        if ok && !out.contains(&lower) {
            out.push(lower);
        }
        if out.len() >= 5 {
            break;
        }
    }
    out
}

const NUM: &str = r"(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|a couple of|couple of|a few|few|several)";
const UNIT: &str = r"(day|week|month|year)s?";
const MONTHS: [&str; 12] = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

fn num(s: &str) -> Option<i64> {
    Some(match s {
        "a" | "an" | "one" => 1,
        "two" | "a couple of" | "couple of" => 2,
        "three" | "a few" | "few" | "several" => 3,
        "four" => 4,
        "five" => 5,
        "six" => 6,
        "seven" => 7,
        "eight" => 8,
        "nine" => 9,
        "ten" => 10,
        "eleven" => 11,
        "twelve" => 12,
        d => d.parse().ok()?,
    })
}

fn day_start(d: NaiveDate) -> DateTime<Utc> {
    Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap())
}

fn back(now: DateTime<Utc>, n: i64, unit: &str) -> DateTime<Utc> {
    match unit {
        "day" => now - Duration::days(n),
        "week" => now - Duration::weeks(n),
        "month" => now.checked_sub_months(Months::new(n.clamp(0, 1200) as u32)).unwrap_or(now),
        _ => now.checked_sub_months(Months::new((n * 12).clamp(0, 1200) as u32)).unwrap_or(now),
    }
}

fn unit_days(unit: &str) -> f64 {
    match unit {
        "day" => 1.0,
        "week" => 7.0,
        "month" => 30.0,
        _ => 365.0,
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

fn weekday(s: &str) -> Option<Weekday> {
    Some(match s {
        "monday" => Weekday::Mon,
        "tuesday" => Weekday::Tue,
        "wednesday" => Weekday::Wed,
        "thursday" => Weekday::Thu,
        "friday" => Weekday::Fri,
        "saturday" => Weekday::Sat,
        _ => Weekday::Sun,
    })
}

static AGO: Lazy<Regex> = Lazy::new(|| Regex::new(&format!(r"\b{NUM}\s+{UNIT}\s+ago\b")).unwrap());
static PAST: Lazy<Regex> = Lazy::new(|| Regex::new(&format!(r"\b(?:past|last|previous)\s+(?:{NUM}\s+)?{UNIT}\b")).unwrap());
static LAST_WEEKDAY: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(last|this past|this|on)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b").unwrap());
static LAST_WEEKEND: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(last|this past) weekend\b").unwrap());
static YESTERDAY: Lazy<Regex> = Lazy::new(|| Regex::new(r"\byesterday\b").unwrap());
static THIS: Lazy<Regex> = Lazy::new(|| Regex::new(r"\bthis\s+(week|month|year)\b").unwrap());
static MONTH: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b(january|february|march|april|june|july|august|september|october|november|december|(?:in|during|of|since|early|mid|late|until|by|through)\s+may|may\s+\d)\b(?:\s+(\d{1,2})(?:st|nd|rd|th)?\b)?").unwrap()
});
static ISO_DATE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b").unwrap());

/// Time windows mentioned in `text`, relative to `now`. Windows are deliberately generous: people
/// say "two weeks ago" for anything from ten days to three weeks, and the conversation that
/// mentions an event usually comes a little after it.
pub fn time_windows(text: &str, now: DateTime<Utc>) -> Vec<TimeWindow> {
    let t = text.to_lowercase();
    let mut out: Vec<TimeWindow> = vec![];
    let fmt = |d: NaiveDate| d.format("%Y-%m-%d (%a)").to_string();
    let mut push = |start: DateTime<Utc>, end: DateTime<Utc>, phrase: &str, meaning: String| {
        if start < end && !out.iter().any(|w| w.start == start && w.end == end) {
            out.push(TimeWindow { start, end, phrase: phrase.to_string(), meaning });
        }
    };
    for c in AGO.captures_iter(&t) {
        let (Some(n), unit) = (num(&c[1]), &c[2]) else { continue };
        let centre = back(now, n, unit);
        let slack_days = (n as f64 * unit_days(unit) * 0.35).max(if unit == "day" { 1.5 } else { 4.0 });
        let slack = Duration::seconds((slack_days * 86_400.0) as i64);
        push(centre - slack, (centre + slack).min(now + Duration::days(1)), &c[0], format!("about {}", fmt(centre.date_naive())));
    }
    for c in PAST.captures_iter(&t) {
        let unit = &c[2];
        let n = c.get(1).and_then(|m| num(m.as_str())).unwrap_or(1);
        // "last month" / "last year" also mean the previous calendar period.
        if c.get(1).is_none() && c[0].starts_with("last") && (unit == "month" || unit == "year") {
            let today = now.date_naive();
            let (s, e) = if unit == "month" {
                let first = today.with_day(1).unwrap();
                (first.checked_sub_months(Months::new(1)).unwrap(), first)
            } else {
                (NaiveDate::from_ymd_opt(today.year() - 1, 1, 1).unwrap(), NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap())
            };
            let pad = Duration::days(if unit == "month" { 7 } else { 30 });
            let meaning = if unit == "month" { s.format("%B %Y").to_string() } else { s.format("%Y").to_string() };
            push(day_start(s) - pad, (day_start(e) + pad).min(now + Duration::days(1)), &c[0], meaning);
            continue;
        }
        let pad = Duration::days(if unit == "day" { 1 } else { 3 });
        push(back(now, n, unit) - pad, now + Duration::days(1), &c[0], format!("since {}", fmt(back(now, n, unit).date_naive())));
    }
    for c in LAST_WEEKDAY.captures_iter(&t) {
        let wd = weekday(&c[2]).unwrap();
        let today = now.date_naive();
        let mut d = today - Duration::days(1);
        while d.weekday() != wd {
            d -= Duration::days(1);
        }
        // "this Saturday" asked on a Saturday may mean today.
        if &c[1] != "last" && today.weekday() == wd {
            d = today;
        }
        push(day_start(d) - Duration::days(1), day_start(d) + Duration::days(3), &c[0], fmt(d));
    }
    for c in LAST_WEEKEND.captures_iter(&t) {
        let mut d = now.date_naive() - Duration::days(1);
        while d.weekday() != Weekday::Sat {
            d -= Duration::days(1);
        }
        push(day_start(d) - Duration::days(1), day_start(d) + Duration::days(4), &c[0], format!("{} to {}", fmt(d), fmt(d + Duration::days(1))));
    }
    for c in YESTERDAY.captures_iter(&t) {
        let d = now.date_naive() - Duration::days(1);
        push(day_start(d) - Duration::days(1), now + Duration::days(1), &c[0], fmt(d));
    }
    for c in THIS.captures_iter(&t) {
        let today = now.date_naive();
        let s = match &c[1] {
            "week" => today - Duration::days(today.weekday().num_days_from_monday() as i64),
            "month" => today.with_day(1).unwrap(),
            _ => NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap(),
        };
        push(day_start(s) - Duration::days(2), now + Duration::days(1), &c[0], format!("since {}", fmt(s)));
    }
    for c in MONTH.captures_iter(&t) {
        let word = c[1].split_whitespace().find(|w| MONTHS.contains(w)).unwrap_or("may");
        let m = MONTHS.iter().position(|x| *x == word).unwrap() as u32 + 1;
        let (s, e) = month_range(m, now);
        let day = c.get(2).and_then(|d| d.as_str().parse::<u32>().ok()).filter(|d| (1..=31).contains(d));
        match day.and_then(|d| NaiveDate::from_ymd_opt(s.year(), m, d)) {
            Some(d) => push(day_start(d) - Duration::days(2), day_start(d) + Duration::days(5), &c[0], fmt(d)),
            None => push(s - Duration::days(3), e + Duration::days(7), &c[0], s.format("%B %Y").to_string()),
        }
    }
    for c in ISO_DATE.captures_iter(&t) {
        if let Some(d) = NaiveDate::from_ymd_opt(c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0), c[3].parse().unwrap_or(0)) {
            push(day_start(d) - Duration::days(2), day_start(d) + Duration::days(5), &c[0], fmt(d));
        }
    }
    out
}

static QUOTED: Lazy<Regex> = Lazy::new(|| Regex::new(r#"(?:^|[\s(])['"‘“]([^'"‘’“”]{3,80})['"’”](?:[\s,.?!:;)]|$)"#).unwrap());
static BETWEEN: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\bbetween\s+(.+?)\s+and\s+(.+?)\s*(?:[?!]|\.\s*$|$)").unwrap());
static CLAUSE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\s+(?:when|before|after|since|while|until)\s+").unwrap());
static LEAD: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)^(?:which|what|who|whom|whose|when|where|how\s+(?:many\s+\w+|much|long|old|often)?|did|do|does|was|were|is|are|had|have|has)\b\s*").unwrap());
static ARTICLE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(?:the|a|an|my|our|that|those)\s+").unwrap());

fn clean(s: &str) -> String {
    let s = s.trim().trim_matches(|c: char| c == '?' || c == '.' || c == '!' || c == ',' || c.is_whitespace());
    ARTICLE.replace(s, "").trim().to_string()
}

fn words(s: &str) -> usize {
    s.split_whitespace().count()
}

/// Sub-queries for questions about several things at once. Empty for ordinary questions.
pub fn subqueries(text: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    let mut push = |s: String| {
        if words(&s) >= 1 && s.len() >= 3 && !out.iter().any(|o| o.eq_ignore_ascii_case(&s)) && out.len() < 4 {
            out.push(s);
        }
    };
    let q = text.trim();
    for c in QUOTED.captures_iter(q) {
        push(c[1].trim().to_string());
    }
    // "Which X did I do first, the A or the B?"
    if let Some((head, tail)) = q.rsplit_once(',') {
        let alts: Vec<&str> = tail.split(" or ").collect();
        if alts.len() >= 2 {
            let head = LEAD.replace(head.trim(), "").to_string();
            for a in alts {
                let a = clean(a);
                if !a.is_empty() {
                    push(format!("{head} {a}"));
                }
            }
        }
    } else if q.contains(" or ") && !q.contains(" or not") {
        // "Did I buy the A or the B first?"
        let body = LEAD.replace(q, "").to_string();
        let parts: Vec<&str> = body.split(" or ").collect();
        if parts.len() == 2 && words(parts[0]) <= 12 && words(parts[1]) <= 12 {
            push(clean(parts[0]));
            push(clean(parts[1]));
        }
    }
    if let Some(c) = BETWEEN.captures(q) {
        push(clean(&c[1]));
        push(clean(&c[2]));
    }
    // "How long had I been a member of X when I attended the meetup?"
    let parts: Vec<&str> = CLAUSE.split(q).collect();
    if parts.len() == 2 && words(parts[0]) >= 3 && words(parts[1]) >= 3 {
        push(clean(&LEAD.replace(parts[0], "")));
        push(clean(parts[1]));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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
