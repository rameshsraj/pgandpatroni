# SQL evidence capture

- historical/: full archived command outputs and pgbench client traces, retaining multiline queries.
- all-commands.jsonl: main command records AND separate post-benchmark maintenance records.
- sql-command-records.jsonl: psql invocations, SQL stdin, timestamps, exit status and original output references (relative to each source run).
- server/: all currently retained PostgreSQL log files, including the stopped elastic node, when requested.
- collection-commands.jsonl: collection times, commands and failures; nonzero exit means missing coverage.
- index.json and SHA256SUMS.csv: source inventory and capture integrity.

No SQL was replayed. Attempted statements are not proof of successful commit.
Client traces contain expanded pgbench SQL; transaction timing logs alone do not.
Server logs are retained text, not a deduplicated query count. Multiline records are preserved.
Collection of live files is not atomic; buffered statements or later writes may be absent.
Rotated/deleted logs and commands never recorded cannot be reconstructed.
Known configured passwords are redacted; other sensitive SQL literals may remain.
This directory is intentionally Git-ignored. Store it in an access-controlled evidence archive.
