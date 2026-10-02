ARG POSTGRES_BASE_IMAGE=postgres:16-bookworm
FROM ${POSTGRES_BASE_IMAGE}

RUN apt-get update \
    && apt-get install --yes --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY docker/postgres/entrypoint.sh /usr/local/bin/accio-postgres-entrypoint
COPY docker/postgres/docker-entrypoint-initdb.d/10-load-tpch.sh /docker-entrypoint-initdb.d/10-load-tpch.sh
COPY docker/postgres/job-schema.sql /opt/accio/job-schema.sql

RUN chmod 0755 \
    /opt/accio \
    /usr/local/bin/accio-postgres-entrypoint \
    /docker-entrypoint-initdb.d/10-load-tpch.sh \
    && chmod 0644 /opt/accio/job-schema.sql

ENTRYPOINT ["accio-postgres-entrypoint"]
CMD ["postgres"]
