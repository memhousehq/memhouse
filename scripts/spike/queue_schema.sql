-- Intake queue candidate: one Postgres table claimed with FOR UPDATE SKIP LOCKED (as mh_enrich_job).
DROP TABLE IF EXISTS spike_queue;
CREATE TABLE spike_queue (
  id bigserial PRIMARY KEY,
  subject text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  run_after timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz
);
CREATE INDEX spike_queue_pending ON spike_queue (run_after, id) WHERE status = 'pending';
INSERT INTO spike_queue (subject, payload)
SELECT 'customer:' || (g % 20000), jsonb_build_object('messages', 2, 'chars', 600)
FROM generate_series(1, 300000) g;
ANALYZE spike_queue;
