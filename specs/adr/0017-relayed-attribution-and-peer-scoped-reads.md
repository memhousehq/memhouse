<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0017: Relayed attribution and peer-scoped reads

Status: Accepted.

## Context

The old rule was simple. An authenticated caller always spoke as its own Peer.
A `"peer_key"` in the request body was ignored. Nobody could post under another
person's name, because a name could not be supplied at all.

That rule is correct for a person who is signed in as themselves. It is wrong
for a relayed transcript. An agent submits turns that other people spoke. Under
the old rule every one of those turns was attributed to the agent's Peer, and
the agent became the only nameable subject in the Account.

Four failures followed:

- Every personal statement was filed against an infrastructure identity. A
  human who spoke in the conversation held no Peer and owned nothing.
- Consent was granted by the wrong party to itself. The subject of the
  statement and the caller that submitted it were one identity.
- The personal-knowledge hold could never fire. A statement about the speaker
  is direct evidence at the speaker's own level, so nothing was aimed above the
  subject's peer level and no upward decision was ever owed.
- Erasure by subject could not reach a human's statements.
  `MemHouse.Governance.Erasure` selects on `subject_peer_id`, and no human held
  one.

Reads had the mirror defect. A read was performed as the credential's own Peer,
so an agent received whatever the agent happened to be the subject of, and
nothing that belonged to the people it was asking for.

## Decision

The credential names the party. It is not itself the party.

On ingest, a machine credential — identity kind `:api_key` or `:system` —
that sends `"peer_key"` attributes the turn to that named Peer. The Peer is
created on first use. A password session always speaks as itself, and a
`"peer_key"` in its body is ignored. An internal caller holds no Peer and must
supply one.

On a read, `search`, `ask`, `get_context`, and the knowledge listing accept
`"peer_key"`. It names the peer the results are read for. A reader peer sees
public and internal statements, its own statements, statements about the scope
rather than about a person, and anything promoted to scope or account level. A
machine credential that names no reader peer sees public statements only.
Server-side work — projection rebuild, dream-time, the evaluation harness —
reads the whole corpus, and that posture comes from the absence of an
authenticated identity, never from request input.

Authority does not travel with the attribution. The actor keeps the calling
credential's own roles and authorized scopes in both directions. Relaying as a
Peer with wider grants cannot widen what a request may write, and reading for a
peer does not add that peer's grants.

An existing Peer is resolved, not upserted. A relayed key that already names an
agent Peer must not be rewritten as a person, because an agent that passes for
human returns to the subject allowlist.

Audit records both identities. The relaying credential stays `actor_peer_id`,
and the speaker is written beside it as metadata `"speaker_peer_id"`.

## Consequences

Statements are filed against the people who spoke them. Consent, the upward
hold, and erasure by subject now act on a human Peer, so all three do what they
were built to do. The subject allowlist offered to the extractor is the
session's participants without agent-kind peers, which is a direct result of
the same decision.

The accepted cost is deliberate. A machine credential can attribute an
observation to any Peer in its Account, and can read as any Peer in its
Account. The named key is trusted on the credential's word. Per-peer
authentication is not built yet, and a per-peer key is what closes this. Until
then an API key is as sensitive as the whole Account's memory. Do not share one
key between parties who must not read each other.

The rejected alternative is the old rule: keep ignoring `"peer_key"` and let
the relaying agent be the speaker. It is safe only in the narrow sense that no
single name can be forged. It forges every name at once, because it files the
memory of every participant under one machine identity. Do not re-propose it as
a hardening measure.

## Not done

- No new message column for the relayed speaker. `Message.peer_id` is the
  speaker. The relaying credential appears in the audit entry alone. A second
  column would give every reader of a message two peers to choose between, and
  the wrong one would be the plausible default.
- No re-extraction and no quarantine of statements already stored against an
  agent Peer. Existing rows stay as they are.

## Evidence

- `lib/memhouse/memory.ex` — attribution, reader resolution, allowlist.
- `lib/memhouse/observations/changes.ex` — the two audited identities.
- `lib/memhouse/retrieval/store.ex` — the reader filter every query applies.
- `test/memhouse/ingest_relay_test.exs`
- `test/memhouse/reader_visibility_test.exs`
