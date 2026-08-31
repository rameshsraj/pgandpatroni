-- 10-validate.sql
-- Run on coordinator, connected to customer_orders database.
-- AFTER rebalancing has completed.
--
-- Validates data integrity: no rows lost, no duplicates,
-- queries return correct results.

\echo '=== DATA INTEGRITY VALIDATION ==='
\echo ''

-- ============================================================
-- 1. Total row counts (must match pre-rebalance counts)
-- ============================================================
\echo '--- Total row counts ---'
SELECT 'customers'   AS table_name, count(*) AS total FROM customers
UNION ALL
SELECT 'orders',                    count(*)          FROM orders
UNION ALL
SELECT 'order_items',               count(*)          FROM order_items
ORDER BY table_name;

-- ============================================================
-- 2. Check for duplicate customer_ids
-- ============================================================
\echo ''
\echo '--- Duplicate customer_id check (should return 0) ---'
SELECT count(*) AS duplicate_customers
FROM (
    SELECT customer_id FROM customers
    GROUP BY customer_id HAVING count(*) > 1
) dupes;

-- ============================================================
-- 3. Check for duplicate order_ids (per customer)
-- ============================================================
\echo ''
\echo '--- Duplicate order check (should return 0) ---'
SELECT count(*) AS duplicate_orders
FROM (
    SELECT order_id, customer_id FROM orders
    GROUP BY order_id, customer_id HAVING count(*) > 1
) dupes;

-- ============================================================
-- 4. Referential integrity: every order has a valid customer
-- ============================================================
\echo ''
\echo '--- Orphan orders (should return 0) ---'
SELECT count(*) AS orphan_orders
FROM orders o
LEFT JOIN customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- ============================================================
-- 5. Referential integrity: every order_item has a valid order
-- ============================================================
\echo ''
\echo '--- Orphan order_items (should return 0) ---'
SELECT count(*) AS orphan_items
FROM order_items oi
LEFT JOIN orders o ON oi.order_id = o.order_id AND oi.customer_id = o.customer_id
WHERE o.order_id IS NULL;

-- ============================================================
-- 6. Verify co-located JOIN still works
-- ============================================================
\echo ''
\echo '--- Co-located JOIN: customer 42 ---'
SELECT c.name, count(o.order_id) AS order_count
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE c.customer_id = 42
GROUP BY c.name;

-- ============================================================
-- 7. Verify three-table JOIN still works
-- ============================================================
\echo ''
\echo '--- Three-table JOIN: customer 100 item count ---'
SELECT c.name,
       count(DISTINCT o.order_id) AS orders,
       count(oi.item_id)          AS items
FROM customers c
JOIN orders o      ON c.customer_id = o.customer_id
JOIN order_items oi ON o.order_id = oi.order_id AND o.customer_id = oi.customer_id
WHERE c.customer_id = 100
GROUP BY c.name;

-- ============================================================
-- 8. Verify aggregate query returns same totals
-- ============================================================
\echo ''
\echo '--- Revenue by city (top 5) ---'
SELECT c.city,
       count(DISTINCT c.customer_id) AS customers,
       count(o.order_id)             AS orders,
       round(sum(o.total_amount), 2) AS total_revenue
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
GROUP BY c.city
ORDER BY total_revenue DESC
LIMIT 5;

-- ============================================================
-- 9. Min/max customer_id range (should be 1-500)
-- ============================================================
\echo ''
\echo '--- Customer ID range ---'
SELECT min(customer_id) AS min_id, max(customer_id) AS max_id FROM customers;

\echo ''
\echo '=== VALIDATION COMPLETE ==='
