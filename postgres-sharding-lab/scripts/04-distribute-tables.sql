-- 04-distribute-tables.sql
-- Run on coordinator, connected to customer_orders database.
-- AFTER 03-create-schema.sql has been executed.
--
-- This converts the regular PostgreSQL tables into Citus distributed tables.
-- Each table is distributed (sharded) on customer_id.
-- The colocate_with option ensures that rows with the same customer_id
-- across all three tables land on the same physical shard.
-- This makes JOINs on customer_id local to a single shard — no network hops.

-- Distribute customers first (it has no foreign key dependencies)
SELECT create_distributed_table('customers', 'customer_id');

-- Distribute orders, co-located with customers
SELECT create_distributed_table('orders', 'customer_id', colocate_with => 'customers');

-- Distribute order_items, co-located with customers (and therefore orders)
SELECT create_distributed_table('order_items', 'customer_id', colocate_with => 'customers');

-- Verify distribution
SELECT logicalrelid::text AS table_name,
       partmethod,
       partkey,
       colocationid,
       repmodel
FROM pg_dist_partition
ORDER BY logicalrelid::text;
