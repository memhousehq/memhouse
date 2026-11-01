-- Can clinician C read patient P now? Directly treating, or member of a team assigned to the
-- patient's ward. Returns the granting chain (explainable decision, TR-AZ-04).
\set c random(1, 5000)
\set p random(1, 100000)
SELECT coalesce(
  (SELECT 'treating' FROM spike_tuple WHERE object = 'patient:' || :p AND relation = 'treating' AND subject = 'clinician:' || :c
     AND valid_from <= now() AND (valid_to IS NULL OR valid_to > now()) LIMIT 1),
  (SELECT 'ward ' || a.subject || ' via ' || t.object FROM spike_tuple a
     JOIN spike_tuple w ON w.subject = a.subject AND w.relation = 'assigned'
     JOIN spike_tuple t ON t.object = w.subject AND t.relation = 'member' AND t.subject = 'clinician:' || :c
   WHERE a.object = 'patient:' || :p AND a.relation = 'admitted'
     AND now() BETWEEN a.valid_from AND coalesce(a.valid_to, 'infinity') AND now() BETWEEN w.valid_from AND coalesce(w.valid_to, 'infinity')
     AND now() BETWEEN t.valid_from AND coalesce(t.valid_to, 'infinity') LIMIT 1),
  'deny');
