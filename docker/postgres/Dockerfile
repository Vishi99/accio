ARG POSTGRES_BASE_IMAGE=postgres:16-bookworm
FROM ${POSTGRES_BASE_IMAGE}

RUN apt-get update \
    && apt-get install --yes --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY docker/postgres/entrypoint.sh /usr/local/bin/accio-postgres-entrypoint
COPY docker/postgres/docker-entrypoint-initdb.d/10-load-tpch.sh /docker-entrypoint-initdb.d/10-load-tpch.sh

RUN chmod 0755 \
    /usr/local/bin/accio-postgres-entrypoint \
    /docker-entrypoint-initdb.d/10-load-tpch.sh

ENTRYPOINT ["accio-postgres-entrypoint"]
CMD ["postgres"]
