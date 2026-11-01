\set s random(1, 20000)
INSERT INTO spike_queue (subject, payload) VALUES ('customer:' || :s, '{"messages": 2, "chars": 600}');
