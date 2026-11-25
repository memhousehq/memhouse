// SPDX-License-Identifier: Apache-2.0
/**
 * Lifecycle hooks for an agent loop (INT-03).
 *
 * Four moments of a conversation, each mapped to an API call:
 *
 * | Hook | When | API call |
 * |---|---|---|
 * | `beforeModelCall` | before the model is called | `recall` (with `render`) |
 * | `afterTurn` | after the assistant answered | `ingest` |
 * | `onToolResult` | when a tool returned | `remember` |
 * | `atSessionEnd` | when the conversation is over | `ingest` of what was buffered |
 *
 * The hooks hold no enforcement: no filtering, no gating, no labels, no decision about what is
 * stored or returned. Redaction, the injection screen, the write gate, access control and the
 * audit log all run in the MemHouse engine, for a caller that uses the hooks and for one that
 * calls the API itself alike. Removing the hooks changes nothing about what is enforced.
 */
import type { MemHouse } from "./client.js";
import type { IngestRequest, IngestResult, Message, RecallRequest, RecallResult, RememberRequest, RememberResult } from "./generated.js";

export interface MemoryHooksOptions {
  /**
   * Keep the turns in memory and send them in one `ingest` at session end, instead of one
   * `ingest` per turn. A process that dies before `atSessionEnd` loses the buffered turns,
   * which is why it is off by default.
   */
  bufferTurns?: boolean;
  /** Ask the API to answer with the write gate's decision instead of at once. */
  wait?: boolean;
  /** The source label of what the hooks write (the API's default when not given). */
  source?: string;
}

/** The hooks of one conversation (`sessionId`) about one `subject`. */
export class MemoryHooks {
  readonly client: MemHouse;
  readonly subject: string;
  /** Groups the conversation's rounds; a new id when none was given. */
  readonly sessionId: string;
  readonly options: MemoryHooksOptions;
  /** The whole answer of the latest `beforeModelCall` (hits, ids, `recall_id`). */
  lastRecall: RecallResult | undefined;
  #buffer: Message[] = [];

  constructor(client: MemHouse, subject: string, sessionId?: string, options: MemoryHooksOptions = {}) {
    this.client = client;
    this.subject = subject;
    this.sessionId = sessionId || `session-${crypto.randomUUID()}`;
    this.options = options;
  }

  /**
   * Recall what is known for `query` and return it as a text block ready for the prompt.
   *
   * `recallOptions` are further fields of the recall request (`k`, `kinds`, `tags`,
   * `token_budget`, `render_format`, `scope`, ...). The whole answer is in `lastRecall`. An
   * empty string means nothing was recalled.
   */
  async beforeModelCall(query: string, recallOptions: Partial<RecallRequest> = {}): Promise<string> {
    const result = await this.client.recall({ subject: this.subject, query, render: true, ...recallOptions });
    this.lastRecall = result;
    return result.rendered ?? "";
  }

  /**
   * Propose the finished turn as memory. Resolves to the API's answer, or `null` when the turn
   * was buffered for `atSessionEnd`.
   *
   * A turn goes through `ingest`, not `remember`: `ingest` is the operation for a
   * conversation. It stores the user message and the reply as one round (an episodic record
   * of what was said), screens it for injection, groups it under the session id, and leaves
   * extracting facts from it to the engine's background enrichment. `remember` proposes one
   * statement that stands alone, which a raw turn is not.
   */
  async afterTurn(userMessage: string, assistantMessage: string): Promise<IngestResult | null> {
    const round: Message[] = [
      { role: "user", content: userMessage },
      { role: "assistant", content: assistantMessage },
    ];
    if (this.options.bufferTurns) {
      this.#buffer.push(...round);
      return null;
    }
    return this.#ingest(round);
  }

  /**
   * Propose a tool's result as a memory. `result` is sent as given: text as it is, anything
   * else as JSON.
   *
   * A tool result goes through `remember`, not `ingest`: it is one statement from outside the
   * conversation, not a user/assistant round, so it should pass the whole write pipeline
   * (injection screen, statement gate, routing, duplicate check), and the caller gets the
   * record's id and state back. A plan or a guess is then held as a candidate and an
   * instruction to the agent is quarantined, by the engine.
   */
  async onToolResult(toolName: string, result: unknown): Promise<RememberResult> {
    const content = typeof result === "string" ? result : JSON.stringify(result);
    const request: RememberRequest = {
      subject: this.subject,
      content,
      source: this.options.source ?? `tool:${toolName}`,
      metadata: { tool: toolName, session_id: this.sessionId },
    };
    if (this.options.wait) request.wait = true;
    return this.client.remember(request);
  }

  /**
   * The consolidation trigger: send the buffered turns in one `ingest` under the session id.
   * Resolves to the API's answer, or `null` when nothing was buffered.
   *
   * The API has no separate consolidation route. A session is the unit of background
   * enrichment: every `ingest` under a session id queues the session for it (when enrichment
   * is on), so turns already sent by `afterTurn` need nothing more here.
   */
  async atSessionEnd(): Promise<IngestResult | null> {
    if (this.#buffer.length === 0) return null;
    const messages = [...this.#buffer];
    const result = await this.#ingest(messages);
    // Dropped only once the API has them: a failed call can be tried again.
    this.#buffer.splice(0, messages.length);
    return result;
  }

  #ingest(messages: Message[]): Promise<IngestResult> {
    const request: IngestRequest = { subject: this.subject, session_id: this.sessionId, messages };
    if (this.options.source) request.source = this.options.source;
    if (this.options.wait) request.wait = true;
    return this.client.ingest(request);
  }
}
