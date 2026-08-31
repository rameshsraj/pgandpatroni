#!/bin/bash
set -e

# Render the Patroni configuration from the template
# substituting environment variables for placeholders.

cp /etc/patroni/patroni-template.yml /etc/patroni/patroni.yml

sed -i "s|PATRONI_NAME_PLACEHOLDER|${PATRONI_NAME}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_CONNECT_ADDRESS_PLACEHOLDER|${PATRONI_NAME}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_PG_CONNECT_PLACEHOLDER|${PATRONI_NAME}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_ETCD_HOSTS_PLACEHOLDER|${PATRONI_ETCD3_HOSTS}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_SU_USER_PLACEHOLDER|${PATRONI_SUPERUSER_USERNAME}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_SU_PASS_PLACEHOLDER|${PATRONI_SUPERUSER_PASSWORD}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_REPL_USER_PLACEHOLDER|${PATRONI_REPLICATION_USERNAME}|g" /etc/patroni/patroni.yml
sed -i "s|PATRONI_REPL_PASS_PLACEHOLDER|${PATRONI_REPLICATION_PASSWORD}|g" /etc/patroni/patroni.yml
sed -i "s|APP_USER_PLACEHOLDER|${POSTGRES_APP_USER}|g" /etc/patroni/patroni.yml
sed -i "s|APP_PASSWORD_PLACEHOLDER|${POSTGRES_APP_PASSWORD}|g" /etc/patroni/patroni.yml

echo "=== Rendered Patroni config for ${PATRONI_NAME} ==="
cat /etc/patroni/patroni.yml
echo "=== Starting Patroni ==="

exec patroni /etc/patroni/patroni.yml
