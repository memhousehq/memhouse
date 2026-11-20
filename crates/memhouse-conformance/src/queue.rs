// SPDX-License-Identifier: Apache-2.0
//! The intake-queue kit (TR-LT-05, TR-IN-07): a write is acknowledged once its proposal is in
//! the queue, so the queue must keep it, hand it out once at a time and in order per subject,
//! give it out again when a worker dies, and drop it when its subject is erased.

use crate::{unless, Report};
use chrono::Utc;
use memhouse_core::intake::{Entry, Op, PendingRecord, Proposal};
use memhouse_core::traits::IntakeQueue;
use memhouse_core::types::*;
use std::sync::Arc;
use uuid::Uuid;

pub(crate) fn memory(tenant: &str, subject: &str, content: &str) -> Memory {
    let now = Utc::now();
    Memory {
        id: Uuid::now_v7(),
        tenant: tenant.into(),
        subject: subject.into(),
        kind: MemoryKind::Semantic,
        status: MemoryStatus::Candidate,
        content: content.into(),
        session_id: None,
        turn_ref: None,
        occurred_at: None,
        valid_from: now,
        valid_to: None,
        supersedes: None,
        labels: vec![],
        tags: vec![],
        source: "conformance".into(),
        confidence: 1.0,
        metadata: serde_json::json!({}),
        created_at: now,
        expires_at: None,
        scope: Scope::default(),
        provenance: Provenance::default(),
        language: None,
    }
}

/// A claimed job for a failure message: its first record's text (or its id, when an adapter
/// hands back a proposal without records) and its attempt.
fn said(j: &memhouse_core::intake::IntakeJob) -> (String, i32) {
    (j.proposal.records.first().map(|r| r.memory.content.clone()).unwrap_or_else(|| format!("proposal {} without records", j.proposal.id)), j.attempts)
}

fn proposal(tenant: &str, subject: &str, content: &str) -> Proposal {
    let m = memory(tenant, subject, content);
    Proposal {
        id: m.id,
        tenant: tenant.into(),
        subject: subject.into(),
        actor: "conformance".into(),
        user: None,
        source: "conformance".into(),
        op: Op::Remember,
        entry: Entry::Commit,
        records: vec![PendingRecord {
            content_hash: memhouse_core::engine::content_hash(content),
            memory: m,
            redactions: vec![],
            focus: None,
            structured: None,
            code_refs: vec![],
        }],
        session_id: None,
        enqueued_at: Utc::now(),
    }
}

/// The intake-queue contract. The kit works in a tenant of its own (a fresh name on every run)
/// and leaves nothing unfinished behind.
pub async fn run_intake_queue_kit(q: Arc<dyn IntakeQueue>) -> Report {
    let mut r = Report::new("intake queue", q.name());
    let tenant = format!("kit-{}", Uuid::new_v4().simple());
    let t = tenant.as_str();
    let (a, b) = ("kit:queue-a", "kit:queue-b");
    let claim_a = |lease: u64| {
        let q = q.clone();
        async move { q.claim(10, lease, Some((t, a))).await }
    };

    let (first, second) = (proposal(t, a, "The first write of subject A."), proposal(t, a, "The second write of subject A."));
    let enq = async {
        q.enqueue(&first).await?;
        q.enqueue(&second).await?;
        anyhow::Ok(())
    }
    .await;
    if let Err(e) = enq {
        r.check("enqueue", "a proposal is accepted", Some(format!("the adapter returned an error: {e:#}")));
        return r;
    }
    r.outcome(
        "pending_is_readable",
        "a queued record reads back as a candidate with its content, and its proposal is unfinished",
        async {
            let m = q.pending(t, first.id).await?;
            let ok = m.as_ref().is_some_and(|m| m.status == MemoryStatus::Candidate && m.content == first.records[0].memory.content)
                && q.unfinished(first.id).await?
                && q.subject_unfinished(t, a).await?
                && q.pending_proposal(t, first.id).await? == Some(first.id);
            Ok(unless(ok, || format!("pending: {:?}", m.map(|m| (m.status.as_str().to_string(), m.content)))))
        }
        .await,
    );
    r.outcome(
        "other_tenant_cannot_read",
        "another tenant does not see the queued record",
        async {
            let m = q.pending("kit-someone-else", first.id).await?;
            Ok(unless(m.is_none(), || "the record was returned to another tenant".into()))
        }
        .await,
    );
    r.outcome(
        "status_counts",
        "the tenant's status counts its two pending proposals",
        async {
            let s = q.status(Some(t)).await?;
            Ok(unless(s.pending == 2 && s.running == 0, || format!("pending {}, running {}", s.pending, s.running)))
        }
        .await,
    );

    // One at a time and in order per subject.
    let job = match claim_a(60).await {
        Ok(mut jobs) if jobs.len() == 1 && jobs[0].proposal.id == first.id && jobs[0].attempts == 1 => {
            r.check("claims_in_order_one_per_subject", "a claim gives the subject's oldest proposal only, as attempt 1", None);
            jobs.pop()
        }
        Ok(jobs) => {
            r.check(
                "claims_in_order_one_per_subject",
                "a claim gives the subject's oldest proposal only, as attempt 1",
                Some(format!("{} proposals claimed: {:?}", jobs.len(), jobs.iter().map(said).collect::<Vec<_>>())),
            );
            None
        }
        Err(e) => {
            r.check("claims_in_order_one_per_subject", "a claim gives the subject's oldest proposal only", Some(format!("the adapter returned an error: {e:#}")));
            None
        }
    };
    r.outcome(
        "leased_work_is_not_handed_out_twice",
        "while a proposal is leased, neither it nor a later one of its subject is claimed",
        async {
            let again = claim_a(60).await?;
            Ok(unless(again.is_empty(), || format!("{} proposals claimed during the lease", again.len())))
        }
        .await,
    );
    r.outcome(
        "other_subjects_are_not_blocked",
        "another subject's proposal is claimable while subject A is leased",
        async {
            let other = proposal(t, b, "A write of subject B.");
            q.enqueue(&other).await?;
            let got = q.claim(10, 60, Some((t, b))).await?;
            let ok = got.len() == 1 && got[0].proposal.id == other.id;
            q.finish(other.id, &serde_json::json!({ "kit": "b" })).await?;
            Ok(unless(ok, || format!("{} proposals claimed for subject B", got.len())))
        }
        .await,
    );

    // A failed attempt comes back; a finished one does not, and keeps its outcome.
    if let Some(job) = job {
        r.outcome(
            "failed_attempt_is_retried",
            "a failed attempt is claimable again after its backoff, as attempt 2, still ahead of later writes",
            async {
                q.fail(job.proposal.id, job.attempts, "kit: first attempt failed", false, false).await?;
                let mut got = vec![];
                for _ in 0..80 {
                    got = claim_a(60).await?;
                    if !got.is_empty() {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                if got.len() != 1 || got[0].proposal.id != first.id || got[0].attempts != 2 {
                    return Ok(Some(format!("after 8 s: {:?}", got.iter().map(said).collect::<Vec<_>>())));
                }
                // A retried proposal keeps its content: the retry has to have something to run.
                let texts = |p: &Proposal| p.records.iter().map(|r| r.memory.content.clone()).collect::<Vec<_>>();
                Ok(unless(texts(&got[0].proposal) == texts(&first), || format!("the retried proposal's content is {:?}, not {:?}", texts(&got[0].proposal), texts(&first))))
            }
            .await,
        );
        r.outcome(
            "finished_keeps_its_outcome",
            "a finished proposal is no longer unfinished or pending, and its outcome reads back",
            async {
                let outcome = serde_json::json!({ "kit": "done" });
                q.finish(first.id, &outcome).await?;
                let (unfinished, pending, kept) = (q.unfinished(first.id).await?, q.pending(t, first.id).await?, q.outcome(first.id).await?);
                Ok(unless(!unfinished && pending.is_none() && kept.as_ref().is_some_and(|o| o["kit"] == "done"), || {
                    format!("unfinished: {unfinished}, pending: {}, outcome: {kept:?}", pending.is_some())
                }))
            }
            .await,
        );
    }

    // The second write of A: an expired lease is taken over; a stale worker's report is ignored.
    let mut live_attempt = 2;
    r.outcome(
        "expired_lease_is_taken_over",
        "a proposal whose worker died (its lease ran out) is claimed again, as the next attempt",
        async {
            let one = claim_a(1).await?;
            if one.len() != 1 || one[0].proposal.id != second.id {
                return Ok(Some(format!("the next proposal was not handed out after the first finished ({} claimed)", one.len())));
            }
            tokio::time::sleep(std::time::Duration::from_millis(1600)).await;
            let two = claim_a(60).await?;
            if two.len() != 1 || two[0].proposal.id != second.id || two[0].attempts != one[0].attempts + 1 {
                return Ok(Some(format!("after the lease ran out: {:?}", two.iter().map(|j| j.attempts).collect::<Vec<_>>())));
            }
            live_attempt = two[0].attempts;
            // The first worker wakes up and reports its old attempt as failed for good: no effect.
            q.fail(second.id, one[0].attempts, "kit: a stale worker", true, false).await?;
            let s = q.status(Some(t)).await?;
            Ok(unless(q.unfinished(second.id).await? && s.dead == 0, || format!("a stale attempt's failure changed the proposal (dead: {})", s.dead)))
        }
        .await,
    );
    r.outcome(
        "poison_is_set_aside",
        "a proposal failed for good is set aside: counted as dead, never claimed again, and its record reads as quarantined",
        async {
            let live = claim_a(60).await?;
            anyhow::ensure!(live.is_empty(), "a leased proposal was claimed again");
            q.fail(second.id, live_attempt, "kit: poison", true, false).await?;
            let s = q.status(Some(t)).await?;
            let again = claim_a(60).await?;
            let m = q.pending(t, second.id).await?;
            let ok = s.dead == 1 && again.is_empty() && !q.unfinished(second.id).await? && m.as_ref().is_none_or(|m| m.status == MemoryStatus::Quarantined);
            Ok(unless(ok, || format!("dead: {}, claimed again: {}, record: {:?}", s.dead, again.len(), m.map(|m| m.status.as_str().to_string()))))
        }
        .await,
    );

    // Erasure reaches the queue.
    r.outcome(
        "erasure_drops_queued_writes",
        "discarding a subject removes its unfinished proposals: nothing pending, nothing to claim",
        async {
            let c = "kit:queue-c";
            let (p1, p2) = (proposal(t, c, "A queued write of subject C."), proposal(t, c, "Another queued write of subject C."));
            q.enqueue(&p1).await?;
            q.enqueue(&p2).await?;
            let n = q.discard(t, ForgetScope::Subject, c).await?;
            let left = q.claim(10, 60, Some((t, c))).await?;
            let ok = n == 2 && left.is_empty() && q.pending(t, p1.id).await?.is_none() && !q.subject_unfinished(t, c).await?;
            Ok(unless(ok, || format!("{n} proposals discarded, {} still claimable", left.len())))
        }
        .await,
    );
    r.outcome(
        "prune_removes_only_finished",
        "pruning deletes finished proposals and leaves nothing unfinished behind in the kit's tenant",
        async {
            q.prune(0).await?;
            let s = q.status(Some(t)).await?;
            // Clean up what the kit set aside.
            let _ = q.discard(t, ForgetScope::Tenant, t).await;
            Ok(unless(s.done == 0 && s.pending == 0 && s.running == 0, || format!("after prune: done {}, pending {}, running {}", s.done, s.pending, s.running)))
        }
        .await,
    );
    r
}
