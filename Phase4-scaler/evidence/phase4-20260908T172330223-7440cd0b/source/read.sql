\set first random(1, 99901)
SELECT inet_server_addr() AS server, pg_is_in_recovery() AS replica,
       count(*), sum(id), sum(length(payload))
FROM phase4_lab.items WHERE id BETWEEN :first AND :first + 99;
