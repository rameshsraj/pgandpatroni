#!/bin/bash
# ============================================================
# database-test.sh — Create sample database objects and data
# ============================================================
# Connects through HAProxy (localhost:5000) to ensure we are
# hitting the current primary.
# ============================================================
set -e

# Load .env if present
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

APP_USER="${POSTGRES_APP_USER:-appuser}"
APP_PASS="${POSTGRES_APP_PASSWORD:-appuser-ha-lab-2024}"
APP_DB="${POSTGRES_APP_DATABASE:-appdb}"
SU_USER="${POSTGRES_SUPERUSER:-postgres}"
SU_PASS="${POSTGRES_SUPERUSER_PASSWORD:-postgres-ha-lab-2024}"

echo "========================================"
echo " Database Setup"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================"

# Create the application database if it doesn't exist
echo ""
echo "--- Creating application database and user ---"
PGPASSWORD="$SU_PASS" psql -h localhost -p 5000 -U "$SU_USER" -d postgres -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '$APP_DB') THEN
        CREATE DATABASE $APP_DB;
    END IF;
END
\$\$;
" 2>/dev/null || echo "(database may already exist)"

# Ensure the app user exists with proper permissions
PGPASSWORD="$SU_PASS" psql -h localhost -p 5000 -U "$SU_USER" -d "$APP_DB" -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$APP_USER') THEN
        CREATE ROLE $APP_USER WITH LOGIN PASSWORD '$APP_PASS' CREATEDB CREATEROLE;
    END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE $APP_DB TO $APP_USER;
" 2>/dev/null || echo "(user may already exist)"

PGPASSWORD="$SU_PASS" psql -h localhost -p 5000 -U "$SU_USER" -d "$APP_DB" -c "
GRANT ALL ON SCHEMA public TO $APP_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $APP_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $APP_USER;
"

echo ""
echo "--- Creating tables ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" <<'SQL'

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

SQL

echo ""
echo "--- Inserting sample data ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" <<'SQL'

-- Customers
INSERT INTO customers (name, email) VALUES
    ('Alice Johnson',   'alice@example.com'),
    ('Bob Smith',       'bob@example.com'),
    ('Charlie Brown',   'charlie@example.com'),
    ('Diana Prince',    'diana@example.com'),
    ('Edward Norton',   'edward@example.com')
ON CONFLICT (email) DO NOTHING;

-- Orders
INSERT INTO orders (customer_id, amount, status) VALUES
    (1, 150.00, 'completed'),
    (1,  75.50, 'shipped'),
    (2, 200.00, 'completed'),
    (3,  45.99, 'pending'),
    (4, 320.00, 'completed'),
    (4,  89.99, 'shipped'),
    (5, 110.00, 'pending')
ON CONFLICT DO NOTHING;

-- HA test records (markers for failover testing)
INSERT INTO ha_test (message) VALUES
    ('record-created-before-failover-1'),
    ('record-created-before-failover-2'),
    ('record-created-before-failover-3')
ON CONFLICT DO NOTHING;

SQL

echo ""
echo "--- Verifying data ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" <<'SQL'

SELECT 'customers' AS table_name, count(*) FROM customers
UNION ALL
SELECT 'orders', count(*) FROM orders
UNION ALL
SELECT 'ha_test', count(*) FROM ha_test;

SELECT '--- customers ---' AS "";
SELECT * FROM customers ORDER BY id;

SELECT '--- orders ---' AS "";
SELECT * FROM orders ORDER BY id;

SELECT '--- ha_test ---' AS "";
SELECT * FROM ha_test ORDER BY id;

SQL

echo ""
echo "--- Connection info ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT
    inet_server_addr() AS server_addr,
    inet_server_port() AS server_port,
    current_database() AS database,
    current_user AS user,
    version() AS pg_version,
    pg_is_in_recovery() AS is_replica,
    pg_current_wal_lsn() AS current_lsn;
"

echo ""
echo "Database setup complete."
