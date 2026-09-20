FROM rust:bookworm AS builder

ARG DATAFUSION_POSTGRES_VERSION=0.17.0

RUN cargo install --locked \
        --version "${DATAFUSION_POSTGRES_VERSION}" \
        datafusion-postgres-cli

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        iproute2 \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/cargo/bin/datafusion-postgres-cli /usr/local/bin/
COPY docker/datafusion/entrypoint.sh /usr/local/bin/accio-datafusion-entrypoint

RUN chmod 0755 /usr/local/bin/accio-datafusion-entrypoint

EXPOSE 5432
ENTRYPOINT ["/usr/local/bin/accio-datafusion-entrypoint"]
