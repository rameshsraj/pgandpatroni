-- 03-create-schema.sql
-- Run on coordinator, connected to customer_orders database.
-- Creates the application tables for the sharding demonstration.
-- Tables are created as regular PostgreSQL tables first.
-- Distribution happens in the next step (04-distribute-tables.sql).

-- Customers table: one row per customer.
-- customer_id is the shard key — all related data for a customer
-- lives on the same shard.
CREATE TABLE IF NOT EXISTS customers (
    customer_id BIGSERIAL,
    name        TEXT           NOT NULL,
    email       TEXT           NOT NULL,
    city        TEXT           NOT NULL,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id)
);

-- Orders table: one row per order.
-- The primary key includes customer_id because Citus requires the
-- distribution column to be part of every unique constraint.
-- This is how Citus enforces uniqueness per-shard without a global lock.
CREATE TABLE IF NOT EXISTS orders (
    order_id     BIGSERIAL,
    customer_id  BIGINT         NOT NULL,
    order_date   DATE           NOT NULL DEFAULT CURRENT_DATE,
    total_amount DECIMAL(10,2)  NOT NULL,
    status       TEXT           NOT NULL DEFAULT 'pending',
    PRIMARY KEY (order_id, customer_id),
    CONSTRAINT fk_orders_customer
        FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
);

-- Order items table: line items within an order.
-- customer_id is carried here so it can serve as the distribution column
-- and co-locate order_items with the parent customer and order.
CREATE TABLE IF NOT EXISTS order_items (
    item_id      BIGSERIAL,
    order_id     BIGINT         NOT NULL,
    customer_id  BIGINT         NOT NULL,
    product_name TEXT           NOT NULL,
    quantity     INT            NOT NULL,
    unit_price   DECIMAL(10,2)  NOT NULL,
    PRIMARY KEY (item_id, customer_id),
    CONSTRAINT fk_items_customer
        FOREIGN KEY (customer_id) REFERENCES customers (customer_id),
    CONSTRAINT fk_items_order
        FOREIGN KEY (order_id, customer_id) REFERENCES orders (order_id, customer_id)
);
