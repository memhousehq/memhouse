// SPDX-License-Identifier: Apache-2.0
//! Governance checks for ranking and packing (roadmap G12), on a scratch database:
//!
//! - `ranking_weights`: the order of a controlled set follows the relevance, recency, confidence
//!   and validity weights of the active policy (HYB-05);
//! - `packing_dedup`: over a corpus seeded with duplicates, no two returned memories reach the
//!   configured similarity thresholds, and the freed places are filled (ECON-03);
//! - `token_budget`: 500 recalls with budgets from 200 to 8,000 tokens, none over its budget,
//!   in the structured hits or in the rendered block (PERF-06, INT-04).

use crate::governance::{check, stub_engine, Check, Scratch};
use memhouse_core::pack::{approx_tokens, cosine, overlap, shingles};
use memhouse_core::policy::parse_spec;
use memhouse_core::types::*;
use memhouse_core::Engine;
use uuid::Uuid;

type Outcome = anyhow::Result<(bool, String, String)>;

const TENANT: &str = "default";

fn verdict(problems: Vec<String>, value: String, ok: &str) -> (bool, String, String) {
    (problems.is_empty(), value, if problems.is_empty() { ok.to_string() } else { problems.into_iter().take(8).collect::<Vec<_>>().join("; ") })
}

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    let titles = [
        ("ranking_weights", "HYB-05", "Ranking combines relevance, recency, confidence and validity: changing a weight in the policy changes the order as specified"),
        ("packing_dedup", "ECON-03", "Recall leaves out duplicates and near-duplicates: no two returned memories reach the configured similarity thresholds"),
        (
            "token_budget",
            "PERF-06 / INT-04",
            "The token budget is a hard cap: of 500 recalls with budgets from 200 to 8,000 tokens, none exceeds it, in the hits or in the rendered block",
        ),
    ];
    let results: Vec<Outcome> = match suites(engine).await {
        Ok(r) => r,
        Err(e) => titles.iter().map(|_| Err(anyhow::anyhow!("{e:#}"))).collect(),
    };
    titles
        .iter()
        .zip(results)
        .map(|((id, req, title), r)| match r {
            Ok((passed, value, detail)) => check(id, req, title, passed, value, "all", detail),
            Err(e) => check(id, req, title, false, "error".into(), "all", format!("{e:#}")),
        })
        .collect()
}

async fn suites(base: &Engine) -> anyhow::Result<Vec<Outcome>> {
    let scratch = Scratch::create(base, "pack").await?;
    let out = async {
        let e = stub_engine(base, &scratch.url, "stub:p", 256, "", true).await?;
        let pool = sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(&scratch.url).await?;
        // The checks that activate policies run last, each leaving the default ranking behind.
        let budget = token_budget(&e).await;
        let dedup = packing_dedup(&e).await;
        let weights = ranking_weights(&e, &pool).await;
        Ok::<_, anyhow::Error>(vec![weights, dedup, budget])
    }
    .await;
    scratch.drop().await?;
    out
}

fn write(subject: &str, content: &str, kind: MemoryKind) -> RememberRequest {
    RememberRequest { subject: Some(subject.into()), content: content.into(), kind: Some(kind), wait: true, actor: Some("bench".into()), ..Default::default() }
}

/// Activate a policy with this `[ranking]` body for the tenant.
async fn activate(e: &Engine, n: &mut u32, ranking: &str) -> anyhow::Result<()> {
    *n += 1;
    let spec = parse_spec(&format!("name = \"pack-{n}\"\n[scope]\ntenant = \"{TENANT}\"\n[ranking]\n{ranking}"))?;
    let p = e.policy_propose(TENANT, &spec, "bench", None).await?;
    e.policy_approve(TENANT, p.version, "Dana Reviewer").await?;
    Ok(())
}

/// HYB-05's acceptance test: a controlled set whose order is known for each weight.
async fn ranking_weights(e: &Engine, pool: &sqlx::PgPool) -> Outcome {
    let subj = "customer:ranking";
    let now = chrono::Utc::now();
    let mut problems = vec![];
    // All three answer the question equally by words; they differ in age, confidence and status.
    let old = RememberRequest { occurred_at: Some(now - chrono::Duration::days(700)), ..write(subj, "Acme renewal contract covers forty seats", MemoryKind::Semantic) };
    let recent = RememberRequest { occurred_at: Some(now - chrono::Duration::hours(2)), ..write(subj, "Acme renewal contract includes premium support", MemoryKind::Semantic) };
    let plan =
        RememberRequest { occurred_at: Some(now - chrono::Duration::days(300)), ..write(subj, "Acme plans to sign the renewal contract next quarter", MemoryKind::Semantic) };
    let (old, recent, plan) = (e.remember(old).await?, e.remember(recent).await?, e.remember(plan).await?);
    if old.status != MemoryStatus::Committed || recent.status != MemoryStatus::Committed || plan.status != MemoryStatus::Candidate {
        problems.push(format!("the controlled set was stored as {}, {}, {}", old.status.as_str(), recent.status.as_str(), plan.status.as_str()));
    }
    // The recent record is the less certain one.
    sqlx::query("UPDATE mh_memory SET confidence = 0.2 WHERE id = $1").bind(recent.id).execute(pool).await?;
    let name = |id: Uuid| {
        if id == old.id {
            "old"
        } else if id == recent.id {
            "recent"
        } else if id == plan.id {
            "plan"
        } else {
            "other"
        }
    };
    let order = |include: bool| async move {
        let r = e
            .recall(RecallRequest {
                subject: Some(subj.into()),
                query: "Acme renewal contract".into(),
                k: Some(10),
                analyze: Some(false),
                mode: Some(RetrievalMode::Keyword),
                include_candidates: include,
                ..Default::default()
            })
            .await?;
        anyhow::Ok((r.hits.iter().map(|h| name(h.memory.id)).collect::<Vec<_>>().join(" > "), r.recall_id))
    };
    let mut n = 0;
    let mut seen = vec![];
    // Each case: the policy's ranking, whether candidates are asked for, and the order expected.
    let cases: [(&str, bool, &[&str]); 5] = [
        ("recency_weight = 5.0\nrecency_half_life_days = 30", false, &["recent > old"]),
        ("confidence_weight = 5.0", false, &["old > recent"]),
        ("validity_weight = 5.0", true, &["old > recent > plan", "recent > old > plan"]),
        ("relevance_weight = 0.0\nvalidity_weight = 1.0\nrecency_weight = 0.5\nrecency_half_life_days = 30", true, &["recent > old > plan"]),
        ("relevance_weight = 0.0\nconfidence_weight = 1.0\nrecency_weight = 0.0001", true, &["plan > old > recent", "old > plan > recent"]),
    ];
    for (ranking, include, want) in cases {
        activate(e, &mut n, ranking).await?;
        let (got, _) = order(include).await?;
        if !want.contains(&got.as_str()) {
            problems.push(format!("with [{}]: {got}, expected {}", ranking.replace('\n', ", "), want.join(" or ")));
        }
        seen.push(got);
    }
    // The explanation shows what each score was combined from.
    let (_, recall_id) = order(true).await?;
    match recall_id {
        Some(id) => {
            let rec = e.recall_record(TENANT, id).await?;
            let features: Vec<RankFeatures> = rec.iter().flat_map(|r| r.returned.iter().filter_map(|x| x.features)).collect();
            if features.len() != 3 || !features.iter().any(|f| f.validity == 0.5) || !features.iter().any(|f| (f.confidence - 0.2).abs() < 1e-6) {
                problems.push(format!("the recall explanation lacks the score's features ({features:?})"));
            }
        }
        None => problems.push("the recall has no explanation id".into()),
    }
    // Back to the default weights: relevance alone, as before the policies.
    activate(e, &mut n, "relevance_weight = 1.0").await?;
    Ok(verdict(problems, format!("{} of {} orders as specified", seen.len(), cases.len()), &format!("orders by policy: {}", seen.join("; "))))
}

/// ECON-03's acceptance test: a corpus seeded with duplicates.
async fn packing_dedup(e: &Engine) -> Outcome {
    let subj = "customer:dedup";
    let mut problems = vec![];
    let topics = [
        "the Acme renewal was agreed at forty seats on the annual plan with premium support included",
        "the Acme billing contact moved from Priya to Tom after the reorganisation of the finance team",
        "the Acme security review asked for single sign-on before the renewal contract is signed",
        "the Acme escalation about slow search was closed after the index rebuild last week",
    ];
    let mut originals = vec![];
    let mut seeded = 0;
    for (i, t) in topics.iter().enumerate() {
        originals.push(e.remember(write(subj, &format!("Note: {t}."), MemoryKind::Semantic)).await?.id);
        // The same statement again, as other record types and in other clothes: a different
        // content hash each time, the same words.
        // The first twin has the same words in reverse order: the same vector (the stand-in
        // embedder is a bag of words) and no shingle in common, so only the cosine rule can
        // remove it. The others keep the word order, which the overlap rule also sees.
        let reversed = format!("Note: {}", t.split(' ').rev().collect::<Vec<_>>().join(" "));
        let twins = [
            (MemoryKind::Document, reversed),
            (MemoryKind::Episodic, format!("NOTE - {}!", t.to_uppercase())),
            (MemoryKind::Document, format!("Note: {t}. Ok, so be it.")),
            (MemoryKind::Episodic, format!("note {t} ok")),
        ];
        for (kind, text) in twins.into_iter().take(3 + i % 2) {
            e.remember(write(subj, &text, kind)).await?;
            seeded += 1;
        }
    }
    for t in ["Acme asked about the roadmap for mobile", "Acme's office is in Lisbon near the river", "The Acme champion is Dana from operations"] {
        originals.push(e.remember(write(subj, t, MemoryKind::Semantic)).await?.id);
    }
    let policy = e.policy_for(TENANT).await?;
    let rank = &policy.policy.ranking;
    let mut worst = (0f32, 0f32);
    let (mut removed, mut by_cosine, mut by_overlap) = (0, 0, 0);
    for (q, k) in [
        ("Acme renewal seats annual plan premium support", 7),
        ("Acme billing contact finance team", 5),
        ("Acme security review single sign-on", 4),
        ("Acme slow search escalation index", 10),
    ] {
        let r = e.recall(RecallRequest { subject: Some(subj.into()), query: q.into(), k: Some(k), analyze: Some(false), ..Default::default() }).await?;
        for (i, a) in r.hits.iter().enumerate() {
            for b in &r.hits[i + 1..] {
                // Every hit here comes from the search statement, which returns its vector: a
                // hit without one could not have been compared, so it fails the check.
                let (Some(x), Some(y)) = (&a.embedding, &b.embedding) else {
                    problems.push(format!("'{q}' returned {} or {} without its vector: the cosine rule could not compare them", a.memory.id, b.memory.id));
                    continue;
                };
                let c = cosine(x, y);
                let o = overlap(&shingles(&a.memory.content), &shingles(&b.memory.content));
                worst = (worst.0.max(c), worst.1.max(o));
                if c >= rank.dedup_cosine || o >= rank.dedup_overlap {
                    problems.push(format!("'{q}' returned near-duplicates {} and {} (cosine {c:.3}, overlap {o:.3})", a.memory.id, b.memory.id));
                }
            }
        }
        // Seven distinct statements exist. The places duplicates free are filled from the
        // candidates fetched with the recall (as many again as k): all seven once those cover
        // the corpus, and more than removal alone would leave otherwise.
        let want = if k >= 10 { 7 } else { k.min(5) };
        if r.hits.len() < want || r.hits.len() > k.min(7) {
            problems.push(format!("'{q}' (k = {k}) returned {} memories, expected {want} to {}", r.hits.len(), k.min(7)));
        }
        if let Some(id) = r.recall_id {
            let cut = e.recall_record(TENANT, id).await?.map(|x| x.cut).unwrap_or_default();
            removed += cut.iter().filter(|c| c.reason == ExclusionReason::Duplicate).count();
            by_cosine += cut.iter().filter(|c| c.reason == ExclusionReason::Duplicate && c.detail.starts_with("cosine")).count();
            by_overlap += cut.iter().filter(|c| c.reason == ExclusionReason::Duplicate && c.detail.starts_with("text overlap")).count();
            if cut.iter().any(|c| c.reason == ExclusionReason::Duplicate && topics.iter().any(|t| c.detail.contains(&t[..20]))) {
                problems.push("a duplicate's exclusion detail carries content".into());
            }
        }
    }
    // The cosine rule proved on its own, on one pair tracked by id: the same words in reverse
    // order have the same vector and no shingle in common, so only the cosine rule can remove
    // one of them.
    let pair = "customer:dedup-cosine";
    let (first, second) = ("Note: the gym locker code changed after the spring maintenance weekend", "Note: weekend maintenance spring the after changed code locker gym the");
    let (a, b) = (e.remember(write(pair, first, MemoryKind::Semantic)).await?.id, e.remember(write(pair, second, MemoryKind::Document)).await?.id);
    let vectors = e.embed_passages(&[first.to_string(), second.to_string()]).await?;
    let comparable = vectors.len() == 2 && !vectors[0].is_empty() && vectors[0].len() == vectors[1].len() && vectors.iter().all(|v| v.iter().any(|x| *x != 0.0));
    let (c, o) = (if comparable { cosine(&vectors[0], &vectors[1]) } else { 0.0 }, overlap(&shingles(first), &shingles(second)));
    if !comparable || c < rank.dedup_cosine || o >= rank.dedup_overlap {
        problems.push(format!(
            "the cosine-only pair is not one: vectors comparable {comparable}, cosine {c:.3} (threshold {}), overlap {o:.3} (threshold {})",
            rank.dedup_cosine, rank.dedup_overlap
        ));
    }
    let r = e.recall(RecallRequest { subject: Some(pair.into()), query: "gym locker code maintenance".into(), k: Some(5), analyze: Some(false), ..Default::default() }).await?;
    let cut = match r.recall_id {
        Some(id) => e.recall_record(TENANT, id).await?.map(|x| x.cut).unwrap_or_default(),
        None => vec![],
    };
    let kept: Vec<Uuid> = r.hits.iter().map(|h| h.memory.id).collect();
    let gone: Vec<&ExcludedRecord> = cut.iter().filter(|x| x.reason == ExclusionReason::Duplicate).collect();
    let by_rule = kept.len() == 1
        && [a, b].contains(&kept[0])
        && gone.len() == 1
        && [a, b].contains(&gone[0].id)
        && gone[0].id != kept[0]
        && gone[0].detail.starts_with("cosine")
        && gone[0].detail.contains(&kept[0].to_string());
    if !by_rule {
        problems.push(format!("the cosine-only pair: {} returned, excluded as duplicates: {:?}", kept.len(), gone.iter().map(|x| x.detail.as_str()).collect::<Vec<_>>()));
    }
    if removed == 0 {
        problems.push("no near-duplicate was removed: the corpus was not seeded as intended".into());
    }
    // The same recall with removal turned off by policy returns the duplicates.
    let mut n = 100;
    activate(e, &mut n, "dedup = false").await?;
    let off = e
        .recall(RecallRequest {
            subject: Some(subj.into()),
            query: "Acme renewal seats annual plan premium support".into(),
            k: Some(7),
            analyze: Some(false),
            ..Default::default()
        })
        .await?;
    let twins =
        off.hits.iter().enumerate().any(|(i, a)| off.hits[i + 1..].iter().any(|b| overlap(&shingles(&a.memory.content), &shingles(&b.memory.content)) >= rank.dedup_overlap));
    if !twins {
        problems.push("with dedup = false in the policy the duplicates were still left out".into());
    }
    activate(e, &mut n, "dedup = true").await?;
    Ok(verdict(
        problems,
        format!("0 pairs at a threshold; highest cosine {:.3}, overlap {:.3}", worst.0, worst.1),
        &format!(
            "{seeded} duplicates seeded over {} statements; {removed} removed across 4 recalls, {by_cosine} by cosine and {by_overlap} by text overlap (thresholds: cosine {}, overlap {})",
            originals.len(),
            rank.dedup_cosine,
            rank.dedup_overlap
        ),
    ))
}

/// PERF-06's acceptance test: 500 recalls with budgets from 200 to 8,000 tokens.
async fn token_budget(e: &Engine) -> Outcome {
    let subj = "customer:budget";
    let mut problems = vec![];
    let words = ["renewal", "invoice", "seats", "support", "escalation", "contract", "pricing", "security", "review", "onboarding", "export", "billing"];
    // 60 memories from ~15 to ~1,500 tokens, each about a few of the words.
    for i in 0..60usize {
        let topic: Vec<&str> = (0..3).map(|j| words[(i + j * 5) % words.len()]).collect();
        let sentence = format!("Acme {} {} {} item {i} with detail number {}. ", topic[0], topic[1], topic[2], i * 7919);
        let content = sentence.repeat(1 + (i * i) % 97);
        e.remember(write(subj, content.trim(), if i % 4 == 0 { MemoryKind::Document } else { MemoryKind::Semantic })).await?;
    }
    let formats = [None, Some(RenderFormat::Plain), Some(RenderFormat::Markdown), Some(RenderFormat::Xml)];
    let (mut over, mut empty, mut filled, mut total_used) = (0, 0, 0usize, 0usize);
    for i in 0..500usize {
        let budget = 200 + (i * 7800) / 499;
        let format = formats[i % 4];
        let r = e
            .recall(RecallRequest {
                subject: Some(subj.into()),
                query: format!("Acme {} {}", words[i % words.len()], words[(i / 12 + 3) % words.len()]),
                k: Some(5 + i % 40),
                token_budget: Some(budget),
                render_format: format,
                analyze: Some(false),
                ..Default::default()
            })
            .await?;
        let used: usize = r.hits.iter().map(|h| approx_tokens(&h.memory.content)).sum();
        let block = r.rendered.as_deref().map(approx_tokens);
        if used > budget || block.is_some_and(|b| b > budget) {
            over += 1;
            problems.push(format!("budget {budget}: {used} tokens of content, block {block:?}"));
        }
        if format.is_some() != r.rendered.is_some() {
            problems.push(format!("recall {i}: rendered block {} for format {format:?}", if r.rendered.is_some() { "returned" } else { "missing" }));
        }
        if let (Some(text), Some(f)) = (&r.rendered, format) {
            if !r.hits.iter().all(|h| text.contains(&h.memory.id.to_string())) {
                problems.push(format!("recall {i}: the {} block does not carry every returned id", f.as_str()));
            }
        }
        empty += usize::from(r.hits.is_empty());
        filled += usize::from(used * 2 >= budget.min(2000));
        total_used += used;
    }
    // A cap that returned nothing would pass trivially: the budgets are used.
    if empty > 25 || filled < 250 {
        problems.push(format!("the budget is not used: {empty} of 500 recalls empty, {filled} at least half full"));
    }
    Ok(verdict(
        problems,
        format!("{over} of 500 over budget"),
        &format!("500 recalls, budgets 200 to 8,000 tokens, plain, markdown and xml blocks; {} tokens returned on average, {empty} empty", total_used / 500),
    ))
}
