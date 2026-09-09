\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA phase4_lab;
CREATE TABLE phase4_lab.items (id integer PRIMARY KEY, payload text NOT NULL);
INSERT INTO phase4_lab.items
SELECT i, repeat(md5(i::text), 4) FROM generate_series(1, 100000) AS g(i);
CREATE TABLE phase4_lab.events (token text PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT clock_timestamp());
COMMIT;
ANALYZE phase4_lab.items;
