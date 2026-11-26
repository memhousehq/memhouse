<!-- SPDX-License-Identifier: Apache-2.0 -->
# MemHouse SDK for TypeScript

The TypeScript client for [MemHouse](https://github.com/memhousehq/memhouse), a governed memory
service for AI agents. ESM, Node.js 20 or newer (or any runtime with a global `fetch`), no
runtime dependencies.

```ts
import { MemHouse, MemoryHooks } from "@memhouse/sdk";

const mh = new MemHouse(); // MEMHOUSE_URL (default http://127.0.0.1:7077) and MEMHOUSE_API_KEY

await mh.remember({ subject: "customer:acme", content: "Acme renews on 2027-03-01", wait: true });
const answer = await mh.recall({ subject: "customer:acme", query: "when does Acme renew?", render: true });
console.log(answer.rendered);
```

- **Client.** `MemHouse` has one method per operation of the API (`remember`, `recall`, `revise`,
  `forget`, `ingest`, `getMemory`, `listMemories`, ...), with typed requests and responses. They
  are generated from the OpenAPI specification (`src/generated.ts`, written by `cargo xtask
  sdk`; do not edit it). An error answer rejects with a `MemHouseError` that carries the API's
  stable `code`, its message `error` and the HTTP `status`.
- **Hooks.** `new MemoryHooks(client, subject, sessionId?)` gives an agent loop four calls:
  `beforeModelCall(query)` (recall, resolves to a prompt-ready block), `afterTurn(userMessage,
  assistantMessage)` (ingest), `onToolResult(toolName, result)` (remember) and `atSessionEnd()`
  (sends buffered turns). They only call the API: nothing is enforced in them.
- **Embedded.** `await MemHouse.embedded({ path })` runs the Lite engine in this process instead
  of calling a server; it needs the package `@memhouse/lite` (`bindings/node` of the repository).

The full guide is [docs/sdk.md](../../docs/sdk.md).

## Development

```bash
pnpm install
pnpm typecheck          # tsc --noEmit, strict
pnpm build              # → dist/
pnpm test               # build, then node --test; with MEMHOUSE_URL and MEMHOUSE_API_KEY set, the live test too
```

The tests and `conformance/driver.mjs` import the built `dist/`. The driver serves the profile
conformance suite ([docs/conformance.md](../../docs/conformance.md#the-sdks)):
`scripts/sdk-conformance.sh` from the repository root runs the suite through this SDK against a
throwaway deployment.
