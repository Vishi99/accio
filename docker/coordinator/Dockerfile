FROM python:3.11-bookworm

ARG POSTGRESSCANNER_REPOSITORY=https://github.com/wangxiaoying/postgresscanner.git
ARG POSTGRESSCANNER_REF=prallel_query

ENV DEBIAN_FRONTEND=noninteractive \
    POETRY_VIRTUALENVS_CREATE=false \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/accio \
    DUCK_PG_EXTENSION=/opt/postgresscanner/build/release/extension/postgres_scanner/postgres_scanner.duckdb_extension

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libpq-dev \
        libssl-dev \
        maven \
        ninja-build \
        openjdk-17-jdk-headless \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 \
        --branch "$POSTGRESSCANNER_REF" \
        --recurse-submodules \
        --shallow-submodules \
        "$POSTGRESSCANNER_REPOSITORY" /opt/postgresscanner

# The fork hard-codes OpenSSL 1.1 paths. Bookworm provides OpenSSL 3, so let
# CMake discover the system headers and libraries installed by libssl-dev.
RUN make -C /opt/postgresscanner OPENSSL_FLAG=

WORKDIR /opt/accio
COPY . /opt/accio

RUN python -m pip install --no-cache-dir poetry \
    && poetry install --with dev --no-interaction \
    && python -m pip install --no-cache-dir --editable /opt/postgresscanner/duckdb/tools/pythonpkg \
    && cd rewriter \
    && mvn package -Dmaven.test.skip=true \
    && cp target/accio-rewriter-1.0-SNAPSHOT-jar-with-dependencies.jar /opt/accio/accio/

CMD ["sleep", "infinity"]
