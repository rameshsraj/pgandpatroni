-- 06-inspect-distribution.sql
-- Run on coordinator, connected to customer_orders database.
--
-- Shows exactly where data is physically stored across the cluster.

-- ============================================================
-- 1. Active worker nodes
-- ============================================================
\echo '=== Active worker nodes ==='
SELECT * FROM citus_get_active_worker_nodes() ORDER BY node_name;

-- ============================================================
-- 2. Shard placement for customers table
-- ============================================================
\echo ''
\echo '=== Shard placement: customers ==='
SELECT
    shardid,
    shard_name,
    table_name::text,
    nodename,
    nodeport,
    shard_size
FROM citus_shards
WHERE table_name::text = 'customers'
ORDER BY shardid;

-- ============================================================
-- 3. Shard count per worker
-- ============================================================
\echo ''
\echo '=== Shard count per worker (customers) ==='
SELECT
    nodename,
    count(*) AS shard_count
FROM citus_shards
WHERE table_name::text = 'customers'
GROUP BY nodename
ORDER BY nodename;

-- ============================================================
-- 4. Row count per shard (customers)
-- ============================================================
\echo ''
\echo '=== Row count per shard (customers) ==='
SELECT shardid, success, result AS row_count
FROM run_command_on_shards('customers', $cmd$ SELECT count(*) FROM %s $cmd$)
ORDER BY shardid;

-- ============================================================
-- 5. Row count per worker (customers)
-- ============================================================
\echo ''
\echo '=== Row count per worker (customers) ==='
SELECT
    cs.nodename,
    count(*)            AS shard_count,
    sum(r.result::bigint) AS total_rows
FROM run_command_on_shards('customers', $cmd$ SELECT count(*) FROM %s $cmd$) r
JOIN citus_shards cs USING (shardid)
WHERE cs.table_name::text = 'customers'
GROUP BY cs.nodename
ORDER BY cs.nodename;

-- ============================================================
-- 6. Row count per worker (orders)
-- ============================================================
\echo ''
\echo '=== Row count per worker (orders) ==='
SELECT
    cs.nodename,
    count(*)            AS shard_count,
    sum(r.result::bigint) AS total_rows
FROM run_command_on_shards('orders', $cmd$ SELECT count(*) FROM %s $cmd$) r
JOIN citus_shards cs USING (shardid)
WHERE cs.table_name::text = 'orders'
GROUP BY cs.nodename
ORDER BY cs.nodename;

-- ============================================================
-- 7. Row count per worker (order_items)
-- ============================================================
\echo ''
\echo '=== Row count per worker (order_items) ==='
SELECT
    cs.nodename,
    count(*)            AS shard_count,
    sum(r.result::bigint) AS total_rows
FROM run_command_on_shards('order_items', $cmd$ SELECT count(*) FROM %s $cmd$) r
JOIN citus_shards cs USING (shardid)
WHERE cs.table_name::text = 'order_items'
GROUP BY cs.nodename
ORDER BY cs.nodename;

-- ============================================================
-- 8. Total row counts (via coordinator)
-- ============================================================
\echo ''
\echo '=== Total row counts (via coordinator) ==='
SELECT 'customers'   AS table_name, count(*) AS total FROM customers
UNION ALL
SELECT 'orders',                    count(*)          FROM orders
UNION ALL
SELECT 'order_items',               count(*)          FROM order_items
ORDER BY table_name;

-- ============================================================
-- 9. Co-location group
-- ============================================================
\echo ''
\echo '=== Co-location groups ==='
SELECT logicalrelid::text AS table_name,
       colocationid,
       partmethod,
       repmodel
FROM pg_dist_partition
ORDER BY colocationid, logicalrelid::text;
