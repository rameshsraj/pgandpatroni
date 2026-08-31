FROM postgres:16.4-bookworm

# Install Patroni and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-psycopg2 \
    python3-yaml \
    python3-urllib3 \
    python3-certifi \
    python3-requests \
    python3-six \
    python3-click \
    python3-dateutil \
    python3-prettytable \
    curl \
    jq \
    && pip3 install --break-system-packages patroni[etcd3]==3.3.2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Patroni config directory — writable by postgres user
RUN mkdir -p /etc/patroni && chown postgres:postgres /etc/patroni

EXPOSE 5432 8008

USER postgres

# Entrypoint will render config and start Patroni
CMD ["patroni", "/etc/patroni/patroni.yml"]
