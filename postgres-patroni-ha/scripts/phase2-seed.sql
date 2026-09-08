CREATE TABLE IF NOT EXISTS customers (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(150) NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    amount      NUMERIC(10,2) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ha_test (
    id          SERIAL PRIMARY KEY,
    message     TEXT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now()
);

INSERT INTO customers (name, email) VALUES
    ('Alice Johnson',   'alice@example.com'),
    ('Bob Smith',       'bob@example.com'),
    ('Charlie Brown',   'charlie@example.com'),
    ('Diana Prince',    'diana@example.com'),
    ('Edward Norton',   'edward@example.com')
ON CONFLICT (email) DO NOTHING;

INSERT INTO orders (customer_id, amount, status) VALUES
    (1, 150.00, 'completed'),
    (1,  75.50, 'shipped'),
    (2, 200.00, 'completed'),
    (3,  45.99, 'pending'),
    (4, 320.00, 'completed'),
    (4,  89.99, 'shipped'),
    (5, 110.00, 'pending')
ON CONFLICT DO NOTHING;

INSERT INTO ha_test (message) VALUES
    ('phase2-record-before-node4-added-1'),
    ('phase2-record-before-node4-added-2'),
    ('phase2-record-before-node4-added-3');

SELECT 'customers' AS table_name, count(*) FROM customers
UNION ALL
SELECT 'orders', count(*) FROM orders
UNION ALL
SELECT 'ha_test', count(*) FROM ha_test;
