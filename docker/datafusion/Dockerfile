FROM rust:bookworm AS builder

WORKDIR /build
COPY docker/datafusion/server/Cargo.toml /build/Cargo.toml
COPY docker/datafusion/server/Cargo.lock /build/Cargo.lock
COPY docker/datafusion/server/src /build/src
RUN cargo build --release --locked

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        iproute2 \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/accio-datafusion-source /usr/local/bin/
COPY docker/datafusion/entrypoint.sh /usr/local/bin/accio-datafusion-entrypoint

RUN chmod 0755 /usr/local/bin/accio-datafusion-entrypoint

EXPOSE 5432
ENTRYPOINT ["/usr/local/bin/accio-datafusion-entrypoint"]
