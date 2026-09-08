-- Each transaction reconnects (-C); HAProxy balances connections, not SQL.
-- Only immutable fixture rows are read. Write probes are separate and audited.
\set first random(1, 99901)
SELECT sum(id), sum(length(payload))
FROM phase3_lab.items WHERE id BETWEEN :first AND :first + 99;