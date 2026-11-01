-- One worker iteration: claim the oldest pending job, then mark it done (two statements, one transaction each as a worker would).
WITH c AS (SELECT id FROM spike_queue WHERE status = 'pending' AND run_after <= now() ORDER BY run_after, id LIMIT 1 FOR UPDATE SKIP LOCKED)
UPDATE spike_queue q SET status = 'running', locked_until = now() + interval '5 minutes' FROM c WHERE q.id = c.id RETURNING q.id \gset
UPDATE spike_queue SET status = 'done' WHERE id = :id;
