-- 07-query-routing-demo.sql
-- Run on coordinator, connected to customer_orders database.
--
-- Demonstrates how Citus routes different query types.

-- ============================================================
-- 1. Single-shard query (point lookup by shard key)
--    Citus routes this to exactly one worker — no scatter-gather.
-- ============================================================
\echo '=== Point lookup: single customer ==='
EXPLAIN (VERBOSE) SELECT * FROM customers WHERE customer_id = 42;

\echo ''
SELECT * FROM customers WHERE customer_id = 42;

-- ============================================================
-- 2. Co-located JOIN (same shard key)
--    Because customers and orders are co-located on customer_id,
--    this JOIN executes locally on each shard in parallel.
--    No cross-shard data movement.
-- ============================================================
\echo ''
\echo '=== Co-located JOIN: customer 42 orders ==='
EXPLAIN (VERBOSE)
SELECT c.name, o.order_id, o.order_date, o.total_amount, o.status
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE c.customer_id = 42;

\echo ''
SELECT c.name, o.order_id, o.order_date, o.total_amount, o.status
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE c.customer_id = 42
ORDER BY o.order_date;

-- ============================================================
-- 3. Aggregate across all shards (scatter-gather)
--    Citus sends the query to all shards, each shard computes
--    a partial aggregate, coordinator combines the results.
-- ============================================================
\echo ''
\echo '=== Aggregate: revenue by city ==='
SELECT c.city,
       count(DISTINCT c.customer_id) AS customers,
       count(o.order_id)             AS orders,
       round(sum(o.total_amount), 2) AS total_revenue
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
GROUP BY c.city
ORDER BY total_revenue DESC;

-- ============================================================
-- 4. Three-table co-located JOIN
--    All three tables share the same shard key.
--    The entire JOIN runs locally on each shard.
-- ============================================================
\echo ''
\echo '=== Three-table JOIN: customer 100 full order details ==='
SELECT c.name,
       o.order_id,
       o.order_date,
       oi.product_name,
       oi.quantity,
       oi.unit_price,
       (oi.quantity * oi.unit_price) AS line_total
FROM customers c
JOIN orders o      ON c.customer_id = o.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
                   AND o.customer_id = oi.customer_id
WHERE c.customer_id = 100
ORDER BY o.order_id, oi.item_id
LIMIT 10;

-- ============================================================
-- 5. Which shard owns a given customer_id?
-- ============================================================
\echo ''
\echo '=== Shard ownership for specific customer_ids ==='
SELECT 1::bigint   AS customer_id, get_shard_id_for_distribution_column('customers', 1)   AS shard_id
UNION ALL
SELECT 42,                         get_shard_id_for_distribution_column('customers', 42)
UNION ALL
SELECT 100,                        get_shard_id_for_distribution_column('customers', 100)
UNION ALL
SELECT 250,                        get_shard_id_for_distribution_column('customers', 250)
UNION ALL
SELECT 500,                        get_shard_id_for_distribution_column('customers', 500);
