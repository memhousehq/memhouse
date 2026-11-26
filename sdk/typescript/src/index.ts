// SPDX-License-Identifier: Apache-2.0
/**
 * MemHouse SDK for TypeScript: a governed memory service for AI agents.
 *
 * The client has one method per operation of the API (generated from the OpenAPI
 * specification). `MemoryHooks` are the four lifecycle hooks of an agent loop; they only call
 * the API.
 */
export * from "./generated.js";
export { DEFAULT_URL, HttpTransport, MemHouse, MemHouseError } from "./client.js";
export type { EmbeddedOptions, MemHouseOptions, Transport, TransportResponse } from "./client.js";
export { MemoryHooks } from "./hooks.js";
export type { MemoryHooksOptions } from "./hooks.js";
