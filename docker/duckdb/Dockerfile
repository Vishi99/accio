FROM python:3.11-slim-bookworm

ARG DUCKDB_VERSION=1.5.3

RUN apt-get update \
    && apt-get install --yes --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir "duckdb==${DUCKDB_VERSION}" \
    && python -c "import duckdb; connection = duckdb.connect(); connection.execute('INSTALL quack'); connection.close()"

COPY docker/duckdb/serve.py /usr/local/bin/serve-duckdb

EXPOSE 9494
CMD ["python", "/usr/local/bin/serve-duckdb"]
