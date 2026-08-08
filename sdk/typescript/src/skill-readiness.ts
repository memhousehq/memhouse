// SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
//
// Client-side helpers for interpreting a MemHouse skill-readiness report.
//
// Before an agent runs a named skill in a scope, MemHouse can answer "does this peer
// already know enough?". The server evaluates human-authored skill requirement cards
// against governed knowledge and returns a reasoning-free report of what is satisfied,
// what is missing, and what has gone stale. This module turns one such report into a
// decision the calling program can act on: proceed, or stop and ask first.
//
// Transport-neutral by design. Nothing here performs HTTP, MCP, model calls, or any
// other I/O; the caller fetches the report and passes the parsed object in. This is
// NOT a generated SDK — there is no client, no auth handling, no request builder, and
// no published package. The file is meant to be vendored or copied into a caller. A
// fully generated HTTP/MCP client is not part of this release.
//
// Where a report comes from:
//   * POST /api/v1/readiness with a bearer credential and a body carrying `skill` and
//     `scope_path` (optionally `peer_id`/`peer_key` to ask about another peer the caller
//     is allowed to read). The response wraps the report — pass `body.data` in here,
//     not the whole envelope.
//   * the MCP tool `check_readiness`, which returns the report directly.
//
// Rules a caller must not break:
//   * Never override a server blocker. `blocked` is decided server-side against the
//     caller's authorization, the inherited card version, and lifecycle freshness; a
//     client cannot see enough to second-guess it. Required gaps stop execution,
//     preferred gaps only warn.
//   * Never write knowledge from an answer. Neither this module nor its caller may turn
//     an elicited answer into a fact. The answer is submitted as an ordinary raw
//     observation, extracted by the pipeline, and passed through the approval gates;
//     only a fresh readiness check reflects it. Skipping the re-check is a bug.
//   * Keep prompt text and answers out of logs. Prompts are authored card content and
//     answers are peer content. Server-side readiness telemetry records only identities
//     and counts for that reason, and client logging should match.

/**
 * One unsatisfied requirement from a readiness report.
 *
 * Requirement keys come from human-authored requirement cards and inherit down the
 * scope tree, with the nearest scope winning over an ancestor's card. A gap therefore
 * may originate from a scope well above the one being checked.
 *
 * This type intentionally declares only the fields these helpers read. The server sends
 * more (the matched and stale knowledge ids, the selector, the originating scope and
 * card version, a human-readable description); those survive at runtime and are visible
 * once the value is widened, so do not treat the absence of a field here as proof the
 * server omits it.
 */
export type ReadinessGap = {
  /** Stable requirement name from the card, for example `"brand-voice"`. */
  key: string;
  /**
   * `"required"` gaps block the skill; `"preferred"` gaps are advisory and only warn.
   * This is the single distinction that decides whether execution may continue.
   */
  level: "required" | "preferred";
  /**
   * `"missing"` — nothing governed and authorized matches the requirement.
   * `"stale"` — something matches but has expired or is due for revalidation. Staleness
   * is computed the moment an item comes due, so a lagging background sweeper cannot
   * leave a window where a skill looks ready and is not.
   * `"missing_card"` — no active requirement card is visible for this scope at all. An
   * absent card is a blocker, never silent permission to run.
   */
  status: "missing" | "stale" | "missing_card";
  /**
   * Where the missing fact is allowed to come from. `"ask-peer"` means it must be
   * sourced from the peer themselves, `"from-memory"` means it must already exist as
   * governed knowledge the caller may read (so no question can close it), and
   * `"either"` accepts both.
   */
  source_policy: "from-memory" | "ask-peer" | "either";
  /**
   * The server's verdict on whether this gap may be put to the peer as a question, and
   * the round trip an answer has to make.
   */
  elicitation: {
    /** False for `"from-memory"` gaps and for the missing-card blocker. */
    allowed: boolean;
    /** Authored question text. Absent when the card author supplied none. */
    prompt?: string;
    /**
     * Always `"ingest"`: the answer goes back as a raw observation. It is not knowledge
     * until extraction and governance have processed it.
     */
    submit_via?: "ingest";
    /**
     * Always `"check_readiness"`: re-run the check after ingest rather than assuming
     * the answer closed the gap.
     */
    then?: "check_readiness";
  };
};

/**
 * A readiness report as returned by the server.
 *
 * `report_version` pins the contract: `"f9-1"` names the requirement selector language
 * and this gap-report shape. The server changes that string only as a deliberate
 * contract transition, so the literal type here makes an unrecognised report a compile
 * error rather than a silent misread.
 */
export type ReadinessReport = {
  report_version: "f9-1";
  /** True exactly when there are no blockers. */
  ready: boolean;
  /** The authoritative go/no-go flag; the only field that may gate execution. */
  blocked: boolean;
  /** Unmet required requirements. */
  blockers: ReadinessGap[];
  /** Unmet preferred requirements. Never a reason to stop. */
  warnings: ReadinessGap[];
};

/** The actionable summary of one readiness report. */
export type ElicitationPlan = {
  /** The server's `blocked` flag, inverted. Nothing else may gate execution. */
  canProceed: boolean;
  /**
   * Questions that may legitimately be asked, covering required and preferred gaps
   * alike — a preferred answer is still worth collecting. `blocking` marks the ones
   * that currently prevent the skill from running.
   */
  prompts: Array<{ requirementKey: string; prompt: string; blocking: boolean }>;
  /**
   * Required gaps that no question can close: `"from-memory"` requirements and the
   * missing-card blocker. Resolving these needs governed knowledge to arrive by another
   * route, or a curator to publish a card, so surface them to an operator rather than
   * presenting them to the peer as an interview.
   */
  hardBlockers: ReadinessGap[];
  /** Every unmet preferred requirement, kept verbatim so callers can degrade knowingly. */
  warnings: ReadinessGap[];
};

/**
 * Thrown when a guarded skill path is entered while required gaps remain.
 *
 * Carries the untouched report and the derived plan so a handler can render the
 * questions, escalate hard blockers, or retry after answers have been ingested and
 * governed. Catching this and continuing anyway defeats the entire check.
 */
export class SkillReadinessBlockedError extends Error {
  readonly report: ReadinessReport;
  readonly plan: ElicitationPlan;

  constructor(report: ReadinessReport, plan: ElicitationPlan) {
    super("Skill readiness has required gaps.");
    this.name = "SkillReadinessBlockedError";
    this.report = report;
    this.plan = plan;
  }
}

/**
 * Derives an elicitation plan from a readiness report.
 *
 * Pure and side-effect free: no network, no model, no writes, and the report is read
 * rather than mutated. The same report always yields the same plan, which makes this
 * safe to call on a hot path or inside a retry loop.
 *
 * @param report - The parsed report; for HTTP, the value under `data`.
 * @returns The plan. It reports what may be asked; it never decides on its own that
 * execution is acceptable.
 */
export function buildElicitationPlan(report: ReadinessReport): ElicitationPlan {
  // Required and preferred gaps are asked about together, but their consequences differ
  // and must stay distinguishable — `blocking` below carries that difference through.
  const gaps = [...report.blockers, ...report.warnings];
  const prompts = gaps
    // Two independent conditions, both needed. `allowed` is the server's judgement that
    // this gap's source policy permits asking the peer at all; the prompt may still be
    // absent if the card author wrote none, and inventing one here would put a question
    // to the peer that no curator ever approved.
    .filter((gap) => gap.elicitation.allowed && gap.elicitation.prompt)
    .map((gap) => ({
      requirementKey: gap.key,
      // Narrowing only: the filter above already established the prompt is present.
      prompt: gap.elicitation.prompt as string,
      blocking: gap.level === "required",
    }));

  return {
    // Deliberately the server's verdict, not "are there prompts left to ask".
    canProceed: !report.blocked,
    prompts,
    hardBlockers: report.blockers.filter((gap) => !gap.elicitation.allowed),
    warnings: report.warnings,
  };
}

/**
 * Enforcing entry point: refuses to let a skill run while required gaps remain.
 *
 * Call it immediately before running the skill. Preferred gaps never stop execution —
 * they come back in the returned plan's `warnings` so the caller can record the degraded
 * input and continue.
 *
 * @param report - The parsed readiness report.
 * @returns The plan, when the report is not blocked.
 * @throws {SkillReadinessBlockedError} When the server reported required gaps. The
 * correct recovery is to ask the plan's prompts, submit each answer as an ordinary raw
 * observation so extraction and governance can process it, then fetch a fresh report and
 * call this again. Never proceed on the strength of the answers alone.
 */
export function requireSkillReady(report: ReadinessReport): ElicitationPlan {
  const plan = buildElicitationPlan(report);

  if (!plan.canProceed) {
    throw new SkillReadinessBlockedError(report, plan);
  }

  return plan;
}
