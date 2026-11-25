// SPDX-License-Identifier: Apache-2.0
// The client offline: how requests are built and how answers and errors are read.
import assert from "node:assert/strict";
import { test } from "node:test";
import { inspect } from "node:util";

import { API_VERSION, HttpTransport, MemHouse, MemHouseError } from "../dist/index.js";
import { RecordingTransport, withStatus } from "./fakes.mjs";

const FAKE_KEY = "mh_test_0000"; // secret-scan: allow (fake fixture)

function client(answers = [], options = {}) {
  const transport = new RecordingTransport(...answers);
  return [new MemHouse({ baseUrl: "http://memhouse.test", apiKey: FAKE_KEY, transport, ...options }), transport];
}

test("a POST sends the body as JSON with the key as a bearer credential", async () => {
  const [mh, sent] = client([{ id: "1", status: "candidate", deduplicated: false }]);
  const result = await mh.remember({ subject: "customer:acme", content: "Acme renews in March" }, { idempotencyKey: "k-1" });
  assert.equal(result.status, "candidate");
  const [request] = sent.requests;
  assert.equal(`${request.method} ${request.path}`, "POST /v1/remember");
  assert.deepEqual(request.body, { subject: "customer:acme", content: "Acme renews in March" });
  assert.equal(request.headers["authorization"], `Bearer ${FAKE_KEY}`);
  assert.equal(request.headers["content-type"], "application/json");
  assert.equal(request.headers["idempotency-key"], "k-1");
  assert.ok(!("x-memhouse-user" in request.headers));
});

test("path parameters are encoded and unset query parameters left out", async () => {
  const [mh, sent] = client([{ items: [] }, { deleted: 1 }]);
  await mh.listMemories("customer:acme/eu", { includeInactive: true, limit: 5 });
  await mh.revokeGrant("a b");
  assert.deepEqual(sent.calls, ["GET /v1/subjects/customer%3Aacme%2Feu/memories?include_inactive=true&limit=5", "DELETE /v1/grants/a%20b"]);
  assert.equal(sent.requests[0].body, null);
  assert.ok(!("content-type" in sent.requests[0].headers));
});

test("the client's user is sent unless the call names another", async () => {
  const [mh, sent] = client([], { user: "user:ana", actor: "support-bot" });
  await mh.whoami();
  await mh.whoami({ user: "user:ben" });
  assert.deepEqual(sent.requests.map((r) => r.headers["x-memhouse-user"]), ["user:ana", "user:ben"]);
  assert.equal(sent.requests[0].headers["x-memhouse-actor"], "support-bot");
});

test("a text answer is returned as text", async () => {
  const [mh, sent] = client(["memhouse_up 1\n"]);
  assert.equal(await mh.metrics(), "memhouse_up 1\n");
  assert.equal(sent.requests[0].headers["accept"], "text/plain");
});

test("an error answer rejects with the code, the message and the status", async () => {
  const [mh] = client([withStatus(409, { error: "request key 'k' was already used for a different request", code: "conflict" })]);
  await assert.rejects(mh.remember({ content: "x" }), (e) => {
    assert.ok(e instanceof MemHouseError);
    assert.deepEqual([e.status, e.code], [409, "conflict"]);
    assert.match(e.error, /already used/);
    assert.ok(!String(e).includes(FAKE_KEY));
    return true;
  });
});

test("an error without a JSON body gets the code of its status", async () => {
  const [mh] = client([withStatus(503, "upstream is down"), withStatus(418, "")]);
  await assert.rejects(mh.stats(), (e) => e.status === 503 && e.code === "unavailable" && e.error === "upstream is down");
  await assert.rejects(mh.stats(), (e) => e.status === 418 && e.code === "unknown");
});

test("a key repeated by an error answer is not in the error", async () => {
  // A proxy that echoes the request's headers in its error page, as text or as JSON.
  const [mh] = client([
    withStatus(502, `bad gateway; request was: Authorization: Bearer ${FAKE_KEY}`),
    withStatus(401, { error: `the key ${FAKE_KEY} is not known`, code: `unauthorized:${FAKE_KEY}` }),
    withStatus(500, "x".repeat(495) + FAKE_KEY),
  ]);
  for (const status of [502, 401, 500]) {
    await assert.rejects(mh.stats(), (e) => {
      assert.equal(e.status, status);
      assert.ok(!`${e} ${e.message} ${e.error} ${e.code}`.includes(FAKE_KEY.slice(0, 8)), String(e));
      return true;
    });
  }
});

test("an answer that is a JSON array is returned as one", async () => {
  const event = { id: 1, action: "memory.write" };
  const [mh, sent] = client([[], [event], [409, { code: "conflict" }]]);
  assert.deepEqual(await mh.audit(), []);
  assert.deepEqual(await mh.audit(), [event]);
  // An array is a body whatever is in it: a status is given with `withStatus`.
  assert.deepEqual(await mh.audit(), [409, { code: "conflict" }]);
  assert.deepEqual(sent.calls, ["GET /v1/audit", "GET /v1/audit", "GET /v1/audit"]);
});

test("a path parameter cannot name another route", async () => {
  const [mh, sent] = client([{ items: [] }]);
  // `/v1/subjects/../memories` is `/v1/memories` to a URL parser, encoded or not.
  for (const subject of ["..", ".", ""]) {
    await assert.rejects(mh.listMemories(subject), (e) => e instanceof TypeError && /path parameter/.test(e.message));
  }
  await assert.rejects(mh.getMemory(""), TypeError);
  assert.deepEqual(sent.calls, []);
  // Dots inside a longer value, and an encoded slash, are one segment as before.
  await mh.listMemories("../x");
  assert.deepEqual(sent.calls, ["GET /v1/subjects/..%2Fx/memories"]);
});

test("the key from the environment is sent, and an explicit one replaces it", async () => {
  const before = process.env.MEMHOUSE_API_KEY;
  process.env.MEMHOUSE_API_KEY = FAKE_KEY;
  try {
    const transport = new RecordingTransport();
    await new MemHouse({ baseUrl: "http://memhouse.test", transport }).whoami();
    await new MemHouse({ baseUrl: "http://memhouse.test", apiKey: "mh_test_1111", transport }).whoami(); // secret-scan: allow (fake fixture)
    await new MemHouse({ baseUrl: "http://memhouse.test", apiKey: "", transport }).whoami();
    assert.deepEqual(transport.requests.map((r) => r.headers["authorization"]), [`Bearer ${FAKE_KEY}`, "Bearer mh_test_1111", undefined]);
  } finally {
    if (before === undefined) delete process.env.MEMHOUSE_API_KEY;
    else process.env.MEMHOUSE_API_KEY = before;
  }
});

test("URL and key come from the environment, and the key is not shown", async () => {
  const before = { url: process.env.MEMHOUSE_URL, key: process.env.MEMHOUSE_API_KEY };
  process.env.MEMHOUSE_URL = "http://127.0.0.1:1";
  process.env.MEMHOUSE_API_KEY = FAKE_KEY;
  try {
    const mh = new MemHouse();
    assert.equal(mh.baseUrl, "http://127.0.0.1:1");
    assert.ok(!inspect(mh, { depth: 5, showHidden: true }).includes(FAKE_KEY));
    assert.ok(!JSON.stringify(mh).includes(FAKE_KEY));
    // Nothing listens there: no answer is an error of its own, without the key in it.
    await assert.rejects(mh.health(), (e) => e instanceof MemHouseError && e.status === 0 && e.code === "transport" && !String(e).includes(FAKE_KEY));
  } finally {
    for (const [name, value] of [["MEMHOUSE_URL", before.url], ["MEMHOUSE_API_KEY", before.key]]) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});

test("only http URLs are accepted", () => {
  assert.throws(() => new HttpTransport("file:///etc/passwd"), TypeError);
  assert.throws(() => new HttpTransport("not a url"), TypeError);
});

test("a URL that would change the request target is refused", () => {
  // Appending `/health` to these would put the path into the query or the fragment.
  for (const url of ["https://memhouse.test/gateway?region=west", "https://memhouse.test/gateway#api", "https://memhouse.test?"]) {
    assert.throws(() => new HttpTransport(url), /query string or a fragment/);
  }
  // A path prefix is kept in front of every operation's path.
  assert.equal(new HttpTransport("https://memhouse.test/gateway/").baseUrl, "https://memhouse.test/gateway");
  assert.equal(new HttpTransport("http://127.0.0.1:7077").baseUrl, "http://127.0.0.1:7077");
});

test("credentials in the URL are refused and not repeated", async () => {
  for (const url of [`https://ada:${FAKE_KEY}@memhouse.test`, `ftp://ada:${FAKE_KEY}@memhouse.test`, `https://ada:${FAKE_KEY}@memhouse.test:port`, `https://${FAKE_KEY}@memhouse.test`]) {
    assert.throws(
      () => new MemHouse({ baseUrl: url }),
      (e) => e instanceof TypeError && !e.message.includes(FAKE_KEY) && !e.message.includes("ada"),
    );
  }
  // A failed connection names the endpoint, which has no credentials in it.
  await assert.rejects(new HttpTransport("http://127.0.0.1:1/prefix/").request("GET", "/health", null, {}), (e) => e.code === "transport" && e.error.startsWith("no answer from http://127.0.0.1:1/prefix: "));
});

test("embedded says what to install when the binding is missing", async (t) => {
  let installed = true;
  try {
    await import("@memhouse/lite");
  } catch {
    installed = false;
  }
  if (installed) return t.skip("@memhouse/lite is installed here");
  await assert.rejects(MemHouse.embedded(), /@memhouse\/lite/);
});

test("close releases the transport", async () => {
  const [mh, sent] = client();
  await mh.close();
  assert.ok(sent.closed);
});

test("every operation of the specification is a method", () => {
  for (const name of ["remember", "recall", "revise", "forget", "ingest", "getMemory", "listMemories", "review", "whoami"]) {
    assert.equal(typeof MemHouse.prototype[name], "function", name);
  }
  assert.equal(API_VERSION.split(".").length, 3);
});
