// SPDX-License-Identifier: Apache-2.0
/**
 * The MemHouse client: the generated operations over a pluggable transport.
 *
 * A transport carries one request and returns the status and the body's text. The default one
 * is HTTP through the global `fetch`; `MemHouse.embedded()` uses the embedded Lite binding
 * instead, with the same operations and the same engine behind them.
 */
import { type CallOptions, GeneratedClient } from "./generated.js";

export const DEFAULT_URL = "http://127.0.0.1:7077";
const SDK_VERSION = "2.0.0";

/** What a status means when the body carries no `code` (docs/api.md, Errors). */
const STATUS_CODES: Record<number, string> = {
  400: "invalid_request",
  401: "unauthorized",
  403: "forbidden",
  404: "not_found",
  409: "conflict",
  500: "internal",
  503: "unavailable",
};

/**
 * An error answer from the API, or a request that never got one.
 *
 * `code` is the API's stable error code (`invalid_request`, `unauthorized`, `forbidden`,
 * `not_found`, `conflict`, `internal`, `unavailable`): branch on it, never on the message.
 * `status` is the HTTP status, 0 when no answer arrived (`code` is then `transport`).
 */
export class MemHouseError extends Error {
  readonly status: number;
  readonly code: string;
  /** The API's message, for people. */
  readonly error: string;

  constructor(status: number, code: string, error: string) {
    super(status ? `${status} ${code}: ${error}` : `${code}: ${error}`);
    this.name = "MemHouseError";
    this.status = status;
    this.code = code;
    this.error = error;
  }
}

export interface TransportResponse {
  status: number;
  body: string;
}

/** Carries one request. `path` starts with `/` and includes the query string. */
export interface Transport {
  request(method: string, path: string, body: string | null, headers: Record<string, string>): Promise<TransportResponse>;
  close?(): void | Promise<void>;
}

/** HTTP through the global `fetch`: no dependency. */
export class HttpTransport implements Transport {
  readonly baseUrl: string;
  readonly timeoutMs: number;

  constructor(baseUrl: string, timeoutMs = 30_000) {
    let url: URL;
    try {
      url = new URL(baseUrl);
    } catch {
      throw new TypeError(`the MemHouse URL must be http(s)://host[:port], not ${JSON.stringify(baseUrl)}`);
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      throw new TypeError(`the MemHouse URL must be http(s)://host[:port], not ${JSON.stringify(baseUrl)}`);
    }
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.timeoutMs = timeoutMs;
  }

  async request(method: string, path: string, body: string | null, headers: Record<string, string>): Promise<TransportResponse> {
    let response: Response;
    try {
      response = await fetch(this.baseUrl + path, { method, headers, body: body ?? undefined, signal: AbortSignal.timeout(this.timeoutMs) });
      // An error status is an answer: the client maps its body to MemHouseError.
      return { status: response.status, body: await response.text() };
    } catch (e) {
      const cause = e instanceof Error ? ((e.cause as { message?: string } | undefined)?.message ?? e.message) : String(e);
      throw new MemHouseError(0, "transport", `no answer from ${this.baseUrl}: ${cause}`);
    }
  }
}

export interface MemHouseOptions {
  /** Defaults to the environment variable `MEMHOUSE_URL`, then `http://127.0.0.1:7077`. */
  baseUrl?: string;
  /** Defaults to the environment variable `MEMHOUSE_API_KEY`. Never logged or put in an error. */
  apiKey?: string;
  /** The user every call acts for (`x-memhouse-user`), unless a call names another. */
  user?: string;
  /** Deprecated in the API (ignored since 1.1): sent as `x-memhouse-actor` when given. */
  actor?: string;
  /** For the HTTP transport; 30 s by default. */
  timeoutMs?: number;
  /** Replaces HTTP: anything that can carry a request. */
  transport?: Transport;
}

export interface EmbeddedOptions {
  /** The SQLite file (created if missing). */
  path?: string;
  /** A configuration file to read instead. */
  config?: string;
  user?: string;
  actor?: string;
}

function env(name: string): string | undefined {
  return typeof process !== "undefined" ? process.env[name] || undefined : undefined;
}

/** A MemHouse deployment. Every operation of the API is a method (see `GeneratedClient`). */
export class MemHouse extends GeneratedClient {
  readonly baseUrl: string;
  readonly user: string | undefined;
  readonly actor: string | undefined;
  readonly transport: Transport;
  // A private field: not enumerable, so not printed with the object or serialised.
  readonly #apiKey: string | undefined;

  constructor(options: MemHouseOptions = {}) {
    super();
    this.baseUrl = options.baseUrl || env("MEMHOUSE_URL") || DEFAULT_URL;
    this.#apiKey = options.apiKey ?? env("MEMHOUSE_API_KEY");
    this.user = options.user;
    this.actor = options.actor;
    this.transport = options.transport ?? new HttpTransport(this.baseUrl, options.timeoutMs);
  }

  /**
   * A client over the embedded Lite engine, in this process: no server, one SQLite file.
   * Needs the package `@memhouse/lite`.
   */
  static async embedded(options: EmbeddedOptions = {}): Promise<MemHouse> {
    // A variable, so the compiler does not need the optional package to be installed.
    const name = "@memhouse/lite";
    let lite: Transport;
    try {
      const module = await import(name);
      const Lite = module.Lite ?? module.default?.Lite;
      const where = { path: options.path, config: options.config };
      lite = typeof Lite.open === "function" ? await Lite.open(where) : new Lite(options.path, options.config);
    } catch (e) {
      if ((e as { code?: string }).code === "ERR_MODULE_NOT_FOUND" || (e as { code?: string }).code === "MODULE_NOT_FOUND") {
        throw new Error("MemHouse.embedded() needs the embedded Lite binding: install the package `@memhouse/lite` (built from bindings/node of the MemHouse repository)", { cause: e });
      }
      throw e;
    }
    // The embedded engine has no listener and so no key to check: none is sent, whatever the
    // environment holds.
    return new MemHouse({ baseUrl: "embedded:", apiKey: "", user: options.user, actor: options.actor, transport: lite });
  }

  /** Release the transport (the embedded engine's file; nothing for HTTP). */
  async close(): Promise<void> {
    await this.transport.close?.();
  }

  protected override async call<T>(method: string, path: string, options: CallOptions = {}): Promise<T> {
    const sent: Record<string, string> = { accept: options.text ? "text/plain" : "application/json", "user-agent": `memhouse-typescript/${SDK_VERSION}` };
    if (this.#apiKey) sent["authorization"] = `Bearer ${this.#apiKey}`;
    if (this.user) sent["x-memhouse-user"] = this.user;
    if (this.actor) sent["x-memhouse-actor"] = this.actor;
    for (const [name, value] of Object.entries(options.headers ?? {})) {
      if (value !== undefined && value !== null) sent[name.toLowerCase()] = String(value);
    }
    const query = new URLSearchParams();
    for (const [name, value] of Object.entries(options.query ?? {})) {
      if (value !== undefined && value !== null) query.append(name, String(value));
    }
    const target = query.size > 0 ? `${path}?${query}` : path;
    let payload: string | null = null;
    if (options.body !== undefined && options.body !== null) {
      payload = JSON.stringify(options.body);
      sent["content-type"] = "application/json";
    }
    const { status, body } = await this.transport.request(method, target, payload, sent);
    if (status >= 200 && status < 300) {
      if (options.text) return body as T;
      return (body.trim() ? JSON.parse(body) : null) as T;
    }
    throw toError(status, body);
  }
}

function toError(status: number, body: string): MemHouseError {
  let code = STATUS_CODES[status] ?? "unknown";
  let message = body.trim().slice(0, 500) || `HTTP ${status}`;
  try {
    const parsed: unknown = JSON.parse(body);
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      const fields = parsed as { code?: unknown; error?: unknown };
      if (fields.code) code = String(fields.code);
      if (fields.error) message = String(fields.error);
    }
  } catch {
    // not JSON: the status decides
  }
  return new MemHouseError(status, code, message);
}
