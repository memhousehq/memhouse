-- Authorization store candidate: relationship tuples in Postgres (TR-AZ-01), checked by SQL.
-- 100,000 patients, 5,000 clinicians, 500 teams, 50 wards; about 1.1 million tuples.
DROP TABLE IF EXISTS spike_tuple;
CREATE TABLE spike_tuple (
  object text NOT NULL,      -- e.g. patient:42, ward:3, team:7
  relation text NOT NULL,    -- treating, member, assigned, admitted
  subject text NOT NULL,     -- e.g. clinician:9, team:7, ward:3
  valid_from timestamptz NOT NULL DEFAULT now() - interval '1 year',
  valid_to timestamptz,
  purpose text NOT NULL DEFAULT 'care'
);
-- clinician -> team (member): each clinician in 2 teams
INSERT INTO spike_tuple (object, relation, subject) SELECT 'team:' || ((c * 7 + k) % 500), 'member', 'clinician:' || c FROM generate_series(1, 5000) c, generate_series(0, 1) k;
-- team -> ward (assigned): each team covers 2 wards
INSERT INTO spike_tuple (object, relation, subject) SELECT 'ward:' || ((t * 3 + k) % 50), 'assigned', 'team:' || t FROM generate_series(0, 499) t, generate_series(0, 1) k;
-- patient -> ward (admitted)
INSERT INTO spike_tuple (object, relation, subject) SELECT 'patient:' || p, 'admitted', 'ward:' || (p % 50) FROM generate_series(1, 100000) p;
-- patient -> clinician (treating): 10 per patient, 5% already ended
INSERT INTO spike_tuple (object, relation, subject, valid_to) SELECT 'patient:' || p, 'treating', 'clinician:' || ((p * 13 + k * 101) % 5000 + 1), CASE WHEN (p + k) % 20 = 0 THEN now() - interval '1 day' END FROM generate_series(1, 100000) p, generate_series(0, 9) k;
CREATE INDEX spike_tuple_obj ON spike_tuple (object, relation, subject);
CREATE INDEX spike_tuple_sub ON spike_tuple (subject, relation, object);
ANALYZE spike_tuple;
