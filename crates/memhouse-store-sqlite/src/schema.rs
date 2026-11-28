// SPDX-License-Identifier: Apache-2.0
//! The Lite schema: the same logical tables and columns as the Postgres store (TR-CORE-04), in
//! SQLite's types. Timestamps are integer microseconds since the epoch (the precision Postgres
//! keeps), ids are text, arrays and JSON documents are JSON text, vectors are blobs (ADR 0003).

/// What the embedder guard raises; the store turns it into the conflict Postgres reports.
pub(crate) const EMBEDDER_GUARD: &str = "mh_embedder_guard";
/// What the activation guard raises (POL-03).
pub(crate) const POLICY_GUARD: &str = "mh_policy_guard";

/// Idempotent: every statement is `IF NOT EXISTS`.
pub(crate) const DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS mh_memory (
  rid              INTEGER PRIMARY KEY,
  id               TEXT NOT NULL UNIQUE,
  tenant           TEXT NOT NULL,
  subject          TEXT NOT NULL,
  -- The subject as one indexed token, so a keyword MATCH is scoped to the subject (ADR 0002).
  stok             TEXT NOT NULL,
  kind             TEXT NOT NULL,
  status           TEXT NOT NULL,
  content          TEXT NOT NULL,
  content_hash     TEXT NOT NULL,
  -- Half precision, 2 bytes per dimension, little-endian; the bit columns are their signs.
  embedding        BLOB,
  embedding_alt    BLOB,
  embedding_bits     BLOB,
  embedding_alt_bits BLOB,
  alt_hash         TEXT,
  embedder         TEXT,
  embedder_config  TEXT,
  session_id       TEXT,
  turn_ref         TEXT,
  occurred_at      INTEGER,
  valid_from       INTEGER NOT NULL,
  valid_to         INTEGER,
  expires_at       INTEGER,
  supersedes       TEXT,
  superseded_by    TEXT,
  labels           TEXT NOT NULL DEFAULT '[]',
  tags             TEXT NOT NULL DEFAULT '[]',
  scope_org        TEXT,
  scope_team       TEXT,
  scope_agent      TEXT,
  scope_user       TEXT,
  scope_session    TEXT,
  source           TEXT NOT NULL,
  confidence       REAL NOT NULL DEFAULT 1,
  prov_agent       TEXT,
  prov_user        TEXT,
  policy_version   TEXT,
  request_key      TEXT,
  extractor        TEXT,
  extractor_config TEXT,
  metadata         TEXT NOT NULL DEFAULT '{}',
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  language         TEXT,
  -- The earliest `stale_since` of the record's code references (TPL-04); NULL when none is stale.
  stale_since      INTEGER,
  -- Vectors of a re-embedding target until the switch (Postgres adds and drops these columns).
  embedding_next          BLOB,
  embedding_alt_next      BLOB,
  embedding_bits_next     BLOB,
  embedding_alt_bits_next BLOB,
  alt_hash_next           TEXT,
  embedder_next           TEXT,
  embedder_config_next    TEXT
);
CREATE INDEX IF NOT EXISTS mh_memory_subject_idx ON mh_memory (tenant, subject, status, kind);
CREATE INDEX IF NOT EXISTS mh_memory_hash_idx ON mh_memory (tenant, subject, content_hash);
CREATE INDEX IF NOT EXISTS mh_memory_created_idx ON mh_memory (tenant, kind, created_at);
CREATE INDEX IF NOT EXISTS mh_memory_expiry_idx ON mh_memory (tenant, expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS mh_memory_session_idx ON mh_memory (tenant, subject, scope_session) WHERE scope_session IS NOT NULL;
-- No vector index on purpose: per-subject scoring is an exact scan (SCALE-03).

CREATE VIRTUAL TABLE IF NOT EXISTS mh_memory_fts USING fts5(stok, content, content = 'mh_memory', content_rowid = 'rid', tokenize = 'porter unicode61');
CREATE TRIGGER IF NOT EXISTS mh_memory_fts_ai AFTER INSERT ON mh_memory BEGIN
  INSERT INTO mh_memory_fts (rowid, stok, content) VALUES (NEW.rid, NEW.stok, NEW.content);
END;
CREATE TRIGGER IF NOT EXISTS mh_memory_fts_ad AFTER DELETE ON mh_memory BEGIN
  INSERT INTO mh_memory_fts (mh_memory_fts, rowid, stok, content) VALUES ('delete', OLD.rid, OLD.stok, OLD.content);
END;
CREATE TRIGGER IF NOT EXISTS mh_memory_fts_au AFTER UPDATE OF stok, content ON mh_memory BEGIN
  INSERT INTO mh_memory_fts (mh_memory_fts, rowid, stok, content) VALUES ('delete', OLD.rid, OLD.stok, OLD.content);
  INSERT INTO mh_memory_fts (rowid, stok, content) VALUES (NEW.rid, NEW.stok, NEW.content);
END;

-- Every row carries the embedder that wrote it; after a re-embedding, a process still on the old
-- model can't add vectors that would be compared with the new ones.
CREATE TRIGGER IF NOT EXISTS mh_memory_embedder_guard BEFORE INSERT ON mh_memory
WHEN NEW.embedder IS NOT NULL AND NEW.embedder IS NOT (SELECT value FROM mh_meta WHERE key = 'embedder') BEGIN
  SELECT RAISE(ABORT, 'mh_embedder_guard');
END;

-- What the `source_ids` and `promoted_from` lists of a record's metadata point at, one row per
-- source: the index a deletion follows to find derived facts and promotions (MEM-05). Postgres
-- indexes the two metadata lists themselves.
CREATE TABLE IF NOT EXISTS mh_source_ref (
  memory_id TEXT NOT NULL REFERENCES mh_memory (id) ON DELETE CASCADE,
  tenant    TEXT NOT NULL,
  source_id TEXT NOT NULL,
  via       TEXT NOT NULL CHECK (via IN ('source', 'promoted')),
  PRIMARY KEY (memory_id, source_id, via)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_source_ref_source_idx ON mh_source_ref (tenant, source_id);

CREATE TABLE IF NOT EXISTS mh_embed_cache (
  model     TEXT NOT NULL,
  hash      TEXT NOT NULL,
  embedding BLOB NOT NULL,
  PRIMARY KEY (model, hash)
) WITHOUT ROWID;
-- Deletions purge a content's cached vectors under every model.
CREATE INDEX IF NOT EXISTS mh_embed_cache_hash_idx ON mh_embed_cache (hash);

CREATE TABLE IF NOT EXISTS mh_audit (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  at        INTEGER NOT NULL,
  actor     TEXT NOT NULL,
  action    TEXT NOT NULL,
  tenant    TEXT NOT NULL,
  subject   TEXT,
  memory_id TEXT,
  detail    TEXT NOT NULL,
  prev_hash TEXT NOT NULL,
  hash      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS mh_audit_subject_idx ON mh_audit (tenant, subject);

-- Every deletion is recorded so it can be re-applied after a restore from backup (TR-WF-03).
CREATE TABLE IF NOT EXISTS mh_deletion_ledger (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  at        INTEGER NOT NULL,
  tenant    TEXT NOT NULL,
  subject   TEXT,
  memory_id TEXT,
  scope     TEXT NOT NULL,
  actor     TEXT NOT NULL
);

-- Enrichment queue: one job per ingested session (TR-LT-05: a table of the same file).
CREATE TABLE IF NOT EXISTS mh_enrich_job (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant       TEXT NOT NULL,
  subject      TEXT NOT NULL,
  session_id   TEXT NOT NULL,
  round_ids    TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',
  attempts     INTEGER NOT NULL DEFAULT 0,
  run_after    INTEGER NOT NULL,
  locked_until INTEGER,
  enqueued_at  INTEGER NOT NULL,
  finished_at  INTEGER,
  cache_key    TEXT,
  outcome      TEXT,
  error        TEXT
);
CREATE INDEX IF NOT EXISTS mh_enrich_job_queue_idx ON mh_enrich_job (status, run_after) WHERE status IN ('pending', 'running');
CREATE INDEX IF NOT EXISTS mh_enrich_job_subject_idx ON mh_enrich_job (tenant, subject);

CREATE TABLE IF NOT EXISTS mh_llm_cache (
  key        TEXT PRIMARY KEY,
  model      TEXT NOT NULL,
  response   TEXT NOT NULL,
  created_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS mh_structured (
  memory_id   TEXT PRIMARY KEY REFERENCES mh_memory (id) ON DELETE CASCADE,
  tenant      TEXT NOT NULL,
  subject     TEXT NOT NULL,
  record_type TEXT NOT NULL,
  attrs       TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_structured_type_idx ON mh_structured (tenant, subject, record_type);

CREATE TABLE IF NOT EXISTS mh_code_ref (
  memory_id TEXT NOT NULL REFERENCES mh_memory (id) ON DELETE CASCADE,
  tenant    TEXT NOT NULL,
  subject   TEXT NOT NULL,
  path      TEXT NOT NULL,
  blob_hash TEXT NOT NULL,
  -- Since when the file has other content than `blob_hash`, and the hash last seen (TPL-04).
  stale_since INTEGER,
  seen_hash   TEXT,
  PRIMARY KEY (memory_id, path)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_code_ref_path_idx ON mh_code_ref (tenant, subject, path);

CREATE TABLE IF NOT EXISTS mh_link (
  tenant         TEXT NOT NULL,
  subject        TEXT NOT NULL,
  linked_subject TEXT NOT NULL,
  link_type      TEXT NOT NULL,
  memory_id      TEXT REFERENCES mh_memory (id) ON DELETE CASCADE,
  created_by     TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  PRIMARY KEY (tenant, subject, linked_subject, link_type)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_link_linked_idx ON mh_link (tenant, linked_subject);
CREATE INDEX IF NOT EXISTS mh_link_memory_idx ON mh_link (memory_id) WHERE memory_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS mh_request_key (
  tenant       TEXT NOT NULL,
  key          TEXT NOT NULL,
  subject      TEXT NOT NULL,
  operation    TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  response     TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  PRIMARY KEY (tenant, key)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_request_key_subject_idx ON mh_request_key (tenant, subject);

CREATE TABLE IF NOT EXISTS mh_policy (
  version    TEXT PRIMARY KEY,
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS mh_principal (
  id            TEXT PRIMARY KEY,
  tenant        TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('agent', 'user', 'admin')),
  name          TEXT,
  subjects      TEXT NOT NULL DEFAULT '["*"]',
  kinds         TEXT NOT NULL DEFAULT '[]',
  denied_labels TEXT NOT NULL DEFAULT '[]',
  org           TEXT,
  team          TEXT,
  can_commit    INTEGER NOT NULL DEFAULT 0,
  act_as        INTEGER NOT NULL DEFAULT 0,
  disabled_at   INTEGER,
  created_at    INTEGER NOT NULL,
  created_by    TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_principal_tenant_idx ON mh_principal (tenant);

-- Only the sha256 of a key's secret is kept; the key id is public.
CREATE TABLE IF NOT EXISTS mh_api_key (
  id           TEXT PRIMARY KEY,
  principal_id TEXT NOT NULL REFERENCES mh_principal (id),
  hash         TEXT NOT NULL,
  scopes       TEXT NOT NULL,
  expires_at   INTEGER,
  revoked_at   INTEGER,
  created_at   INTEGER NOT NULL,
  created_by   TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_api_key_principal_idx ON mh_api_key (principal_id);

CREATE TABLE IF NOT EXISTS mh_signing_key (
  id         TEXT PRIMARY KEY,
  secret     BLOB NOT NULL,
  created_at INTEGER NOT NULL,
  retired_at INTEGER
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS mh_recall (
  id          TEXT PRIMARY KEY,
  tenant      TEXT NOT NULL,
  subject     TEXT NOT NULL,
  principal   TEXT NOT NULL,
  acting_user TEXT,
  at          INTEGER NOT NULL,
  body        TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_recall_subject_idx ON mh_recall (tenant, subject);
CREATE INDEX IF NOT EXISTS mh_recall_user_idx ON mh_recall (tenant, acting_user) WHERE acting_user IS NOT NULL;
CREATE INDEX IF NOT EXISTS mh_recall_at_idx ON mh_recall (at);

CREATE TABLE IF NOT EXISTS mh_policy_spec (
  tenant      TEXT NOT NULL,
  version     INTEGER NOT NULL CHECK (version > 0),
  name        TEXT NOT NULL,
  spec        TEXT NOT NULL,
  spec_hash   TEXT NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('proposed', 'approved')),
  note        TEXT,
  proposed_by TEXT NOT NULL,
  proposed_at INTEGER NOT NULL,
  approved_by TEXT,
  approved_at INTEGER,
  PRIMARY KEY (tenant, version),
  CHECK ((status = 'approved') = (approved_by IS NOT NULL AND approved_at IS NOT NULL))
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS mh_policy_activation (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant   TEXT NOT NULL,
  version  INTEGER,
  compiled TEXT NOT NULL,
  action   TEXT NOT NULL,
  by_whom  TEXT NOT NULL,
  at       INTEGER NOT NULL,
  FOREIGN KEY (tenant, version) REFERENCES mh_policy_spec (tenant, version)
);
CREATE INDEX IF NOT EXISTS mh_policy_activation_tenant_idx ON mh_policy_activation (tenant, id DESC);
-- Only approved policies execute (POL-03), whoever writes the row.
CREATE TRIGGER IF NOT EXISTS mh_policy_activation_guard BEFORE INSERT ON mh_policy_activation
WHEN NEW.version IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM mh_policy_spec WHERE tenant = NEW.tenant AND version = NEW.version AND status = 'approved') BEGIN
  SELECT RAISE(ABORT, 'mh_policy_guard');
END;

-- The intake queue of the write pipeline (ADR 0004). Content is redacted before it gets here; a
-- finished proposal keeps only its ids and outcome until it is pruned.
CREATE TABLE IF NOT EXISTS mh_intake (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  id           TEXT NOT NULL UNIQUE,
  tenant       TEXT NOT NULL,
  subject      TEXT NOT NULL,
  record_ids   TEXT NOT NULL,
  agent        TEXT,
  acting_user  TEXT,
  source       TEXT,
  scope_agent  TEXT,
  scope_user   TEXT,
  status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'dead')),
  attempts     INTEGER NOT NULL DEFAULT 0,
  run_after    INTEGER NOT NULL,
  locked_until INTEGER,
  enqueued_at  INTEGER NOT NULL,
  finished_at  INTEGER,
  payload      TEXT,
  outcome      TEXT,
  error        TEXT,
  embedder     TEXT
);
CREATE INDEX IF NOT EXISTS mh_intake_order_idx ON mh_intake (tenant, subject, seq) WHERE status IN ('pending', 'running');
CREATE INDEX IF NOT EXISTS mh_intake_tenant_idx ON mh_intake (tenant, status);
CREATE INDEX IF NOT EXISTS mh_intake_done_idx ON mh_intake (finished_at) WHERE status = 'done';
-- A process still on the old model after a re-embedding can't queue writes either.
CREATE TRIGGER IF NOT EXISTS mh_intake_embedder_guard BEFORE INSERT ON mh_intake
WHEN NEW.embedder IS NOT NULL AND NEW.embedder IS NOT (SELECT value FROM mh_meta WHERE key = 'embedder') BEGIN
  SELECT RAISE(ABORT, 'mh_embedder_guard');
END;

CREATE TABLE IF NOT EXISTS mh_grant (
  id         TEXT PRIMARY KEY,
  tenant     TEXT NOT NULL,
  grantor    TEXT NOT NULL,
  grantee    TEXT NOT NULL,
  subjects   TEXT NOT NULL DEFAULT '*',
  kinds      TEXT NOT NULL DEFAULT '[]',
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER,
  revoked_at INTEGER,
  CHECK (grantor <> grantee)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_grant_grantee_idx ON mh_grant (tenant, grantee) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS mh_eval_suite (
  tenant     TEXT NOT NULL,
  name       TEXT NOT NULL,
  hash       TEXT NOT NULL,
  suite      TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (tenant, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS mh_eval_run (
  id             TEXT PRIMARY KEY,
  tenant         TEXT NOT NULL,
  suite          TEXT NOT NULL,
  suite_hash     TEXT NOT NULL,
  policy_version TEXT NOT NULL,
  "trigger"      TEXT NOT NULL,
  run            TEXT NOT NULL,
  created_at     INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_eval_run_suite_idx ON mh_eval_run (tenant, suite, created_at DESC);

-- Console sessions (schema 11, threat model T3). Only the sha256 of a session's secret is
-- kept. A row exists while its session can be used: logout, expiry and the retention pass
-- delete it. No reference to mh_principal: the bootstrap principal has no row there.
CREATE TABLE IF NOT EXISTS mh_session (
  id           TEXT PRIMARY KEY,
  tenant       TEXT NOT NULL,
  principal_id TEXT NOT NULL,
  key_id       TEXT NOT NULL,
  key_check    TEXT,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_session_expires_idx ON mh_session (expires_at);

-- Schema 12 (G22). Legal holds (GOV-09): while a hold is active, every record it matches is
-- exempt from retention and deletion.
CREATE TABLE IF NOT EXISTS mh_legal_hold (
  id          TEXT PRIMARY KEY,
  tenant      TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK (target_kind IN ('subject', 'user', 'agent', 'source', 'org', 'team', 'session', 'tenant')),
  target      TEXT NOT NULL,
  reason      TEXT NOT NULL,
  placed_by   TEXT NOT NULL,
  placed_at   INTEGER NOT NULL,
  released_by TEXT,
  released_at INTEGER
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_legal_hold_active_idx ON mh_legal_hold (tenant) WHERE released_at IS NULL;

-- The deletion workflow (TR-WF-01): one row per forget, from the request to its certificate.
-- Identifiers, counts and hashes only.
CREATE TABLE IF NOT EXISTS mh_deletion_request (
  id           TEXT PRIMARY KEY,
  tenant       TEXT NOT NULL,
  scope        TEXT NOT NULL,
  value        TEXT NOT NULL,
  actor        TEXT NOT NULL,
  requested_at INTEGER NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('running', 'held', 'completed')),
  completed_at INTEGER,
  deleted      INTEGER NOT NULL DEFAULT 0,
  held         INTEGER NOT NULL DEFAULT 0,
  executions   INTEGER NOT NULL DEFAULT 0,
  canaries     TEXT NOT NULL DEFAULT '[]',
  certificate  TEXT
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS mh_deletion_request_open_idx ON mh_deletion_request (tenant, status) WHERE status <> 'completed';
CREATE INDEX IF NOT EXISTS mh_deletion_request_tenant_idx ON mh_deletion_request (tenant, requested_at DESC);

-- Durable job runs (TR-WF-02): at most one unfinished run per tenant and job.
CREATE TABLE IF NOT EXISTS mh_job_run (
  id          TEXT PRIMARY KEY,
  tenant      TEXT NOT NULL,
  job         TEXT NOT NULL,
  state       TEXT NOT NULL DEFAULT '{}',
  started_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  finished_at INTEGER
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS mh_job_run_open_idx ON mh_job_run (tenant, job) WHERE finished_at IS NULL;
"#;
