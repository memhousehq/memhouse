#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// The TypeScript SDK as a way into a deployment, for the profile conformance suite.
//
// Reads one JSON object per line on standard input, `{"op": "remember", "body": {...}}` (the
// operation is `remember`, `recall`, `revise`, `forget` or `ingest`), carries it out with the
// SDK's client and writes one line: `{"ok": true, "result": {...}}` or `{"ok": false, "error":
// "..."}`. The deployment is the one at MEMHOUSE_URL with MEMHOUSE_API_KEY, or with
// MEMHOUSE_EMBEDDED=<database file> the embedded Lite engine. Needs the built SDK (`pnpm
// build`). See docs/conformance.md.
import { createInterface } from "node:readline";

import { MemHouse } from "../dist/index.js";

const OPERATIONS = ["remember", "recall", "revise", "forget", "ingest"];

const embedded = process.env.MEMHOUSE_EMBEDDED;
const client = embedded ? await MemHouse.embedded({ path: embedded }) : new MemHouse();
try {
  for await (const line of createInterface({ input: process.stdin })) {
    if (!line.trim()) continue;
    let answer;
    try {
      const request = JSON.parse(line);
      if (!OPERATIONS.includes(request.op)) throw new Error(`the driver has no operation ${JSON.stringify(request.op)}`);
      answer = { ok: true, result: await client[request.op](request.body ?? {}) };
    } catch (e) {
      // One failed call is one failed step, not the end of the run.
      answer = { ok: false, error: e instanceof Error ? `${e.name}: ${e.message}` : String(e) };
    }
    process.stdout.write(JSON.stringify(answer) + "\n");
  }
} finally {
  await client.close();
}
