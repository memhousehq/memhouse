# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

"""Client-side helpers for interpreting a MemHouse skill-readiness report.

What this module is
-------------------
Before an agent runs a named skill in a scope, MemHouse can answer the question
"does this peer already know enough?". The server evaluates human-authored skill
requirement cards against governed knowledge and returns a *readiness report*: a
reasoning-free list of what is satisfied, what is missing, and what is stale.

This module turns one such report into a decision the calling program can act on:
proceed, or stop and ask the peer some questions first. It is deliberately small
and transport-neutral. It performs no HTTP, no MCP, no model calls, and no I/O of
any kind — you fetch the report however you like and hand the decoded object in.

This is **not** a generated SDK. There is no client, no auth handling, no request
builder, and no published package here; the file is meant to be vendored or copied
into a caller. A fully generated HTTP/MCP client is not part of this release.

Getting a report
----------------
Two server surfaces produce the same report:

* ``POST /api/v1/readiness`` with a bearer credential, body ``skill`` and
  ``scope_path`` (optionally ``peer_id``/``peer_key`` to ask about another peer the
  caller may read). The response wraps the report: pass ``body["data"]`` in here,
  not the whole envelope.
* the MCP tool ``check_readiness``, which returns the report directly.

Report shape this module relies on
----------------------------------
``report_version`` is ``"f9-1"``. That string versions the requirement selector
language and the gap-report shape; the server changes it only as a deliberate
contract transition, so a client may pin it and refuse an unrecognised value.

The fields read below are:

* ``blocked`` — true when at least one *required* requirement is unmet. This is the
  authoritative go/no-go flag and the only thing that decides whether execution may
  continue.
* ``blockers`` — the unmet requirements whose ``level`` is ``"required"``.
* ``warnings`` — the unmet requirements whose ``level`` is ``"preferred"``.
* each gap's ``key`` (the stable requirement name), ``level``, ``status``
  (``"missing"``, ``"stale"``, or ``"missing_card"``), ``source_policy``, and
  ``elicitation`` descriptor.

An absent or unpublished requirement card is itself a blocker (``status`` of
``"missing_card"``), not silent permission to run. Expired knowledge and knowledge
that is due for revalidation count as gaps the moment they come due, so a lagging
background sweeper can never open a window where a skill looks ready and is not.

Rules a caller must not break
-----------------------------
* **Never override a server blocker.** ``blocked`` is decided by the server against
  the caller's authorization, the inherited card version, and lifecycle freshness. A
  client cannot see enough to second-guess it. Required gaps stop execution;
  preferred gaps are advisory and only warn.
* **Never write knowledge from an answer.** Neither this module nor any caller may
  turn an elicited answer into a fact. The answer goes back through ordinary raw
  observation ingest, gets extracted by the pipeline, and passes the approval gates;
  only then does a fresh ``check_readiness`` call reflect it. Every elicitation
  descriptor states this literally with ``submit_via: "ingest"`` followed by
  ``then: "check_readiness"``. Re-running the skill without a re-check is a bug.
* **Only some gaps may be asked about.** A gap carries an elicitation descriptor
  only when its source policy is ``ask-peer`` (the fact must come from the peer
  themselves) or ``either``. A ``from-memory`` gap has ``allowed`` false: no question
  will fix it, because the knowledge has to already exist and be authorized. Those
  land in :attr:`ElicitationPlan.hard_blockers`.
* **Keep prompts out of logs and telemetry.** Prompt text is authored card content;
  answers are peer content. Server-side readiness telemetry records only identities
  and counts for exactly this reason, and client logging should match it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class ElicitationPrompt:
    """One question that may legitimately be put to the peer.

    Attributes:
        requirement_key: Stable requirement name from the card, e.g. ``"brand-voice"``.
            Requirement keys inherit down the scope tree with the nearest scope
            winning, so the same key can come from an ancestor scope's card.
        prompt: Authored question text taken from the card. Treat it as content: show
            it to the peer, do not log it.
        blocking: True when this gap is required and therefore currently prevents the
            skill from running; false when it is merely preferred. Both kinds appear
            in a plan, because asking about a preferred gap is still worthwhile — the
            flag tells the caller which answers actually unblock anything.
    """

    requirement_key: str
    prompt: str
    blocking: bool


@dataclass(frozen=True)
class ElicitationPlan:
    """The actionable summary of one readiness report.

    Attributes:
        can_proceed: Mirrors the server's ``blocked`` flag, inverted. This is the only
            field that may gate execution.
        prompts: Questions that may be asked, for required and preferred gaps alike.
            An empty tuple alongside ``can_proceed`` false means no blocker carried
            both a permitted elicitation and an authored prompt, so there is nothing
            to put to the peer.
        hard_blockers: Required gaps with no permitted question — typically a
            ``from-memory`` requirement, or the missing-card blocker. Resolving these
            needs governed knowledge to arrive by another route, or a curator to
            publish a card; surface them to an operator rather than to the peer.
        warnings: Every unmet preferred requirement, kept verbatim so callers can
            degrade gracefully instead of silently dropping them.
    """

    can_proceed: bool
    prompts: tuple[ElicitationPrompt, ...]
    hard_blockers: tuple[dict[str, Any], ...]
    warnings: tuple[dict[str, Any], ...]


class SkillReadinessBlockedError(RuntimeError):
    """Raised when a helper path attempts to run with required gaps.

    Carries the untouched ``report`` and the derived ``plan`` so a handler can render
    the questions, tell the operator about hard blockers, or retry after the answers
    have been ingested and governed. Catching this exception and continuing anyway
    defeats the entire check.
    """

    def __init__(self, report: dict[str, Any], plan: ElicitationPlan) -> None:
        super().__init__("Skill readiness has required gaps.")
        self.report = report
        self.plan = plan


def build_elicitation_plan(report: dict[str, Any]) -> ElicitationPlan:
    """Convert a readiness report into prompts without performing model calls.

    Pure and side-effect free: no network, no model, no writes. Given the same report
    it always returns the same plan, which is what makes it safe to call on a hot
    path or in a retry loop.

    Args:
        report: The decoded report object — for HTTP, the value under ``"data"``. It
            is read, never mutated, and never copied into the plan except by
            reference in ``hard_blockers`` and ``warnings``.

    Returns:
        An :class:`ElicitationPlan`.

    Raises:
        KeyError: if a gap that advertises an allowed elicitation is missing ``key``
            or ``level``. That means the report did not come from a server speaking
            the ``f9-1`` report contract, and failing loudly beats guessing.
    """

    # Required and preferred gaps are asked about together, but their consequences
    # differ and must stay distinguishable: `blocking` below carries that difference.
    blockers = tuple(report.get("blockers", ()))
    warnings = tuple(report.get("warnings", ()))
    gaps = blockers + warnings

    prompts = tuple(
        ElicitationPrompt(
            requirement_key=gap["key"],
            prompt=gap["elicitation"]["prompt"],
            blocking=gap["level"] == "required",
        )
        for gap in gaps
        # Two independent conditions, both required. `allowed` is the server's
        # judgement that this gap's source policy permits asking the peer at all; a
        # prompt may still be absent if the card author wrote none, and inventing one
        # locally would put a question to the peer that no curator approved.
        if gap.get("elicitation", {}).get("allowed")
        and gap.get("elicitation", {}).get("prompt")
    )

    return ElicitationPlan(
        # Deliberately the server's verdict, not "are there any prompts left". A
        # report that omits `blocked` entirely reads as not blocked, so pass the
        # server's object through verbatim rather than assembling one by hand.
        can_proceed=not bool(report.get("blocked")),
        prompts=prompts,
        # Required gaps no question can close. Kept separate so a caller does not
        # present an unanswerable situation as an interview.
        hard_blockers=tuple(
            gap for gap in blockers if not gap.get("elicitation", {}).get("allowed")
        ),
        warnings=warnings,
    )


def require_skill_ready(report: dict[str, Any]) -> ElicitationPlan:
    """Block the caller's skill path until all required gaps are resolved.

    The enforcing entry point: call it immediately before running the skill and let
    it decide. Preferred gaps never stop execution — they come back in the returned
    plan's ``warnings`` so the caller can note the degraded input and carry on.

    Args:
        report: The decoded readiness report, as for :func:`build_elicitation_plan`.

    Returns:
        The :class:`ElicitationPlan` for a report that is not blocked.

    Raises:
        SkillReadinessBlockedError: when the server reported required gaps. Do not
            swallow it to keep going. The correct recovery is to ask the plan's
            prompts, submit each answer as an ordinary raw observation so extraction
            and governance can process it, then request a fresh report and call this
            function again.
    """

    plan = build_elicitation_plan(report)
    if not plan.can_proceed:
        raise SkillReadinessBlockedError(report, plan)
    return plan
