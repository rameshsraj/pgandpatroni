-- 05-generate-data.sql
-- Run on coordinator, connected to customer_orders database.
-- AFTER 04-distribute-tables.sql has been executed.
--
-- Generates:
--   500 customers
--   2500 orders  (5 per customer)
--   7500 order items (3 per order)
--
-- All INSERTs go through the coordinator, which hashes customer_id
-- and routes each row to the correct shard/worker automatically.

-- ============================================================
-- Customers: 500 rows
-- ============================================================
INSERT INTO customers (name, email, city)
SELECT
    'Customer-' || i,
    'customer' || i || '@example.com',
    (ARRAY[
        'New York', 'London', 'Tokyo', 'Paris', 'Sydney',
        'Berlin', 'Toronto', 'Mumbai', 'São Paulo', 'Singapore'
    ])[1 + (i % 10)]
FROM generate_series(1, 500) AS s(i);

-- ============================================================
-- Orders: 5 per customer = 2500 rows
-- ============================================================
INSERT INTO orders (customer_id, order_date, total_amount, status)
SELECT
    c.customer_id,
    CURRENT_DATE - (floor(random() * 365))::int,
    round((random() * 490 + 10)::numeric, 2),
    (ARRAY['pending', 'shipped', 'delivered', 'cancelled'])[1 + floor(random() * 4)::int]
FROM customers c
CROSS JOIN generate_series(1, 5) AS s(n);

-- ============================================================
-- Order items: 3 per order = 7500 rows
-- ============================================================
INSERT INTO order_items (order_id, customer_id, product_name, quantity, unit_price)
SELECT
    o.order_id,
    o.customer_id,
    (ARRAY[
        'Widget', 'Gadget', 'Gizmo', 'Doohickey',
        'Thingamajig', 'Sprocket', 'Flange', 'Bracket'
    ])[1 + floor(random() * 8)::int],
    1 + floor(random() * 10)::int,
    round((random() * 99 + 1)::numeric, 2)
FROM orders o
CROSS JOIN generate_series(1, 3) AS s(n);

-- ============================================================
-- Summary counts
-- ============================================================
SELECT 'customers'   AS table_name, count(*) AS row_count FROM customers
UNION ALL
SELECT 'orders',                    count(*)              FROM orders
UNION ALL
SELECT 'order_items',               count(*)              FROM order_items
ORDER BY table_name;
