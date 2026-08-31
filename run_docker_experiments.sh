#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TPCH_SCALE="${TPCH_SCALE:-1}"
PROJECT_NAME="${PROJECT_NAME:-accio-expt-sf${TPCH_SCALE}}"
NETWORK_NAME="${NETWORK_NAME:-${PROJECT_NAME}-net}"
PG1_CONTAINER="${PG1_CONTAINER:-${PROJECT_NAME}-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-${PROJECT_NAME}-pg2}"
ACCIO_CONTAINER="${ACCIO_CONTAINER:-${PROJECT_NAME}-accio}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-bookworm}"
POSTGRES_NETEM_IMAGE="${POSTGRES_NETEM_IMAGE:-${PROJECT_NAME}-postgres:16}"
ACCIO_IMAGE="${ACCIO_IMAGE:-${PROJECT_NAME}-accio:latest}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-postgres}"
PG_DATABASE="${PG_DATABASE:-tpch${TPCH_SCALE}}"
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-1GB}"
PG_SHM_SIZE="${PG_SHM_SIZE:-2g}"
PG1_PORT="${PG1_PORT:-55431}"
PG2_PORT="${PG2_PORT:-55432}"
BANDWIDTH="${BANDWIDTH:-1gbit}"
ACCIO_CORES="${ACCIO_CORES:-4}"
ACCIO_MEMORY="${ACCIO_MEMORY:-8GB}"
ACCIO_RUNS="${ACCIO_RUNS:-1}"
ACCIO_STRATEGY="${ACCIO_STRATEGY:-benefit}"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.accio-docker/${PROJECT_NAME}}"
CONFIG_DIR="${STATE_DIR}/config"
RESULTS_DIR="${STATE_DIR}/results"

usage() {
    cat <<'EOF'
Run Accio + DuckDB against two containerized PostgreSQL data sources.

Usage:
  ./run_docker_experiments.sh build
  ./run_docker_experiments.sh up
  ./run_docker_experiments.sh place <v0|v1|v2>
  ./run_docker_experiments.sh run <v0|v1|v2> [query]
  ./run_docker_experiments.sh experiment <v0|v1|v2> [query]
  ./run_docker_experiments.sh all [query]
  ./run_docker_experiments.sh status
  ./run_docker_experiments.sh down
  ./run_docker_experiments.sh destroy

Commands:
  build       Build the PostgreSQL/netem and Accio/custom-DuckDB images.
  up          Start pg1, pg2, and the Accio coordinator containers.
  place       Drop and reload the two databases using one table placement.
  run         Run the matching workload. The requested placement must be loaded.
  experiment  Start containers if needed, load a placement, and run it.
  all         Run v0, v1, and v2, physically reloading each placement.
  status      Show containers, loaded placement, and traffic-control settings.
  down        Remove containers and the Docker network; retain database volumes.
  destroy     Run down and permanently remove both database volumes.

Required for place/experiment/all:
  TPCH_DATA_DIR   Directory containing dbgen region.tbl, nation.tbl, supplier.tbl,
                  customer.tbl, part.tbl, partsupp.tbl, orders.tbl, lineitem.tbl.

Useful environment overrides:
  TPCH_SCALE=1             Database/config scale (supported: 1, 10, 50)
  BANDWIDTH=1gbit          Per-PostgreSQL-container egress limit; use none to disable
  ACCIO_CORES=4            DuckDB threads
  ACCIO_MEMORY=8GB         DuckDB memory limit
  ACCIO_RUNS=1             Executions per query
  ACCIO_STRATEGY=benefit   Accio rewrite strategy
  PG_SHARED_BUFFERS=1GB    PostgreSQL shared_buffers
  PG_SHM_SIZE=2g           PostgreSQL container /dev/shm size

Examples:
  TPCH_DATA_DIR=/data/tpch-sf1 ./run_docker_experiments.sh experiment v1 q05
  TPCH_DATA_DIR=/data/tpch-sf1 ACCIO_RUNS=3 ./run_docker_experiments.sh all q05
  ./run_docker_experiments.sh run v1                 # all q*.sql in tpch2_v1

Notes:
  - DuckDB is embedded in the Accio container; it is not a separate service.
  - BANDWIDTH limits each PostgreSQL container independently. Two concurrent
    sources can therefore deliver up to twice that rate in aggregate.
  - The Accio image builds the postgresscanner prallel_query fork and can take
    a while on its first build.
EOF
}

log() {
    printf '[accio-docker] %s\n' "$*"
}

die() {
    printf '[accio-docker] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_docker() {
    require_command docker
    docker info >/dev/null 2>&1 || die "Docker is installed, but its daemon is not running"
}

validate_scale() {
    case "$TPCH_SCALE" in
        1|10|50) ;;
        *) die "TPCH_SCALE must be 1, 10, or 50 (got: $TPCH_SCALE)" ;;
    esac
}

validate_placement() {
    case "${1:-}" in
        v0|v1|v2) ;;
        *) die "Placement must be v0, v1, or v2 (got: ${1:-<empty>})" ;;
    esac
}

container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

require_running_stack() {
    container_running "$PG1_CONTAINER" || die "$PG1_CONTAINER is not running; run '$0 up' first"
    container_running "$PG2_CONTAINER" || die "$PG2_CONTAINER is not running; run '$0 up' first"
    container_running "$ACCIO_CONTAINER" || die "$ACCIO_CONTAINER is not running; run '$0 up' first"
}

build_postgres_image() {
    log "Building $POSTGRES_NETEM_IMAGE from $POSTGRES_IMAGE"
    docker build \
        --build-arg "POSTGRES_BASE_IMAGE=$POSTGRES_IMAGE" \
        --tag "$POSTGRES_NETEM_IMAGE" \
        --file "$SCRIPT_DIR/docker/postgres/Dockerfile" \
        "$SCRIPT_DIR"
}

build_accio_image() {
    log "Building $ACCIO_IMAGE (includes the custom DuckDB/Postgres scanner)"
    docker build \
        --tag "$ACCIO_IMAGE" \
        --file "$SCRIPT_DIR/docker/coordinator/Dockerfile" \
        "$SCRIPT_DIR"
}

build_images() {
    require_docker
    validate_scale
    build_postgres_image
    build_accio_image
}

write_configs() {
    mkdir -p "$CONFIG_DIR" "$RESULTS_DIR"

    cat >"$CONFIG_DIR/db1.json" <<EOF
{
  "type": "POSTGRES",
  "driver": "org.postgresql.Driver",
  "url": "jdbc:postgresql://${PG1_CONTAINER}:5432/${PG_DATABASE}",
  "username": "${PG_USER}",
  "password": "${PG_PASSWORD}",
  "costParams": {"join": 2.0, "agg": 2.0, "sort": 2.0, "trans": 10.0},
  "cardEstType": "postgres",
  "partitionType": "postgres",
  "partition": {"max_parallelism": 8},
  "dialect": "postgres",
  "disableOps": []
}
EOF

    cat >"$CONFIG_DIR/db2.json" <<EOF
{
  "type": "POSTGRES",
  "driver": "org.postgresql.Driver",
  "url": "jdbc:postgresql://${PG2_CONTAINER}:5432/${PG_DATABASE}",
  "username": "${PG_USER}",
  "password": "${PG_PASSWORD}",
  "costParams": {"join": 2.0, "agg": 2.0, "sort": 2.0, "trans": 10.0},
  "cardEstType": "postgres",
  "partitionType": "postgres",
  "partition": {"max_parallelism": 8},
  "dialect": "postgres",
  "disableOps": []
}
EOF

    cat >"$CONFIG_DIR/local.json" <<'EOF'
{
  "type": "MANUAL",
  "dialect": "postgres",
  "schema": {}
}
EOF
}

wait_for_postgres() {
    local container="$1"
    local attempt
    for attempt in $(seq 1 60); do
        if docker exec "$container" pg_isready -U "$PG_USER" -d "$PG_DATABASE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    docker logs "$container" >&2 || true
    die "PostgreSQL did not become ready in $container"
}

apply_bandwidth_limit() {
    local container="$1"
    if [ "$BANDWIDTH" = "none" ]; then
        docker exec "$container" tc qdisc del dev eth0 root >/dev/null 2>&1 || true
        return
    fi
    docker exec "$container" tc qdisc replace dev eth0 root netem rate "$BANDWIDTH"
}

start_postgres() {
    local container="$1"
    local volume="$2"
    local host_port="$3"

    if container_running "$container"; then
        log "$container is already running"
    elif container_exists "$container"; then
        docker start "$container" >/dev/null
    else
        docker run --detach \
            --name "$container" \
            --network "$NETWORK_NAME" \
            --cap-add NET_ADMIN \
            --shm-size "$PG_SHM_SIZE" \
            --publish "127.0.0.1:${host_port}:5432" \
            --env "POSTGRES_USER=$PG_USER" \
            --env "POSTGRES_PASSWORD=$PG_PASSWORD" \
            --env "POSTGRES_DB=$PG_DATABASE" \
            --volume "${volume}:/var/lib/postgresql/data" \
            "$POSTGRES_NETEM_IMAGE" \
            -c "shared_buffers=$PG_SHARED_BUFFERS" \
            -c max_connections=100 \
            -c max_worker_processes=8 \
            -c max_parallel_workers_per_gather=4 \
            -c max_parallel_workers=8 \
            -c from_collapse_limit=16 \
            -c join_collapse_limit=16 >/dev/null
    fi

    wait_for_postgres "$container"
    apply_bandwidth_limit "$container"
}

up_stack() {
    require_docker
    validate_scale
    write_configs

    docker image inspect "$POSTGRES_NETEM_IMAGE" >/dev/null 2>&1 || build_postgres_image
    docker image inspect "$ACCIO_IMAGE" >/dev/null 2>&1 || build_accio_image
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

    start_postgres "$PG1_CONTAINER" "${PROJECT_NAME}-pg1-data" "$PG1_PORT"
    start_postgres "$PG2_CONTAINER" "${PROJECT_NAME}-pg2-data" "$PG2_PORT"

    if container_running "$ACCIO_CONTAINER"; then
        log "$ACCIO_CONTAINER is already running"
    elif container_exists "$ACCIO_CONTAINER"; then
        docker start "$ACCIO_CONTAINER" >/dev/null
    else
        docker run --detach \
            --name "$ACCIO_CONTAINER" \
            --network "$NETWORK_NAME" \
            --volume "${CONFIG_DIR}:/experiment/config:ro" \
            --volume "${RESULTS_DIR}:/experiment/results" \
            "$ACCIO_IMAGE" >/dev/null
    fi

    log "Stack is ready: $ACCIO_CONTAINER -> {$PG1_CONTAINER,$PG2_CONTAINER}"
}

require_tpch_data() {
    [ -n "${TPCH_DATA_DIR:-}" ] || die "Set TPCH_DATA_DIR to the directory containing dbgen .tbl files"
    [ -d "$TPCH_DATA_DIR" ] || die "TPCH_DATA_DIR is not a directory: $TPCH_DATA_DIR"
    local table
    for table in region nation supplier customer part partsupp orders lineitem; do
        [ -f "$TPCH_DATA_DIR/$table.tbl" ] || die "Missing $TPCH_DATA_DIR/$table.tbl"
    done
}

reset_schema() {
    local container="$1"
    docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DATABASE" <<'SQL'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO public;
SQL
}

table_ddl() {
    case "$1" in
        region) cat <<'SQL'
CREATE TABLE region (
  r_regionkey INTEGER NOT NULL,
  r_name CHAR(25) NOT NULL,
  r_comment VARCHAR(152)
);
SQL
            ;;
        nation) cat <<'SQL'
CREATE TABLE nation (
  n_nationkey INTEGER NOT NULL,
  n_name CHAR(25) NOT NULL,
  n_regionkey INTEGER NOT NULL,
  n_comment VARCHAR(152)
);
SQL
            ;;
        supplier) cat <<'SQL'
CREATE TABLE supplier (
  s_suppkey BIGINT NOT NULL,
  s_name CHAR(25) NOT NULL,
  s_address VARCHAR(40) NOT NULL,
  s_nationkey INTEGER NOT NULL,
  s_phone CHAR(15) NOT NULL,
  s_acctbal NUMERIC(15,2) NOT NULL,
  s_comment VARCHAR(101) NOT NULL
);
SQL
            ;;
        customer) cat <<'SQL'
CREATE TABLE customer (
  c_custkey BIGINT NOT NULL,
  c_name VARCHAR(25) NOT NULL,
  c_address VARCHAR(40) NOT NULL,
  c_nationkey INTEGER NOT NULL,
  c_phone CHAR(15) NOT NULL,
  c_acctbal NUMERIC(15,2) NOT NULL,
  c_mktsegment CHAR(10) NOT NULL,
  c_comment VARCHAR(117) NOT NULL
);
SQL
            ;;
        part) cat <<'SQL'
CREATE TABLE part (
  p_partkey BIGINT NOT NULL,
  p_name VARCHAR(55) NOT NULL,
  p_mfgr CHAR(25) NOT NULL,
  p_brand CHAR(10) NOT NULL,
  p_type VARCHAR(25) NOT NULL,
  p_size INTEGER NOT NULL,
  p_container CHAR(10) NOT NULL,
  p_retailprice NUMERIC(15,2) NOT NULL,
  p_comment VARCHAR(23) NOT NULL
);
SQL
            ;;
        partsupp) cat <<'SQL'
CREATE TABLE partsupp (
  ps_partkey BIGINT NOT NULL,
  ps_suppkey BIGINT NOT NULL,
  ps_availqty INTEGER NOT NULL,
  ps_supplycost NUMERIC(15,2) NOT NULL,
  ps_comment VARCHAR(199) NOT NULL
);
SQL
            ;;
        orders) cat <<'SQL'
CREATE TABLE orders (
  o_orderkey BIGINT NOT NULL,
  o_custkey BIGINT NOT NULL,
  o_orderstatus CHAR(1) NOT NULL,
  o_totalprice NUMERIC(15,2) NOT NULL,
  o_orderdate DATE NOT NULL,
  o_orderpriority CHAR(15) NOT NULL,
  o_clerk CHAR(15) NOT NULL,
  o_shippriority INTEGER NOT NULL,
  o_comment VARCHAR(79) NOT NULL
);
SQL
            ;;
        lineitem) cat <<'SQL'
CREATE TABLE lineitem (
  l_orderkey BIGINT NOT NULL,
  l_partkey BIGINT NOT NULL,
  l_suppkey BIGINT NOT NULL,
  l_linenumber INTEGER NOT NULL,
  l_quantity NUMERIC(15,2) NOT NULL,
  l_extendedprice NUMERIC(15,2) NOT NULL,
  l_discount NUMERIC(15,2) NOT NULL,
  l_tax NUMERIC(15,2) NOT NULL,
  l_returnflag CHAR(1) NOT NULL,
  l_linestatus CHAR(1) NOT NULL,
  l_shipdate DATE NOT NULL,
  l_commitdate DATE NOT NULL,
  l_receiptdate DATE NOT NULL,
  l_shipinstruct CHAR(25) NOT NULL,
  l_shipmode CHAR(10) NOT NULL,
  l_comment VARCHAR(44) NOT NULL
);
SQL
            ;;
        *) die "Unknown TPC-H table: $1" ;;
    esac
}

load_table() {
    local container="$1"
    local table="$2"
    log "Loading $table into $container"
    table_ddl "$table" | docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DATABASE"
    sed 's/|$//' "$TPCH_DATA_DIR/${table}.tbl" | docker exec -i "$container" \
        psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DATABASE" \
        -c "COPY ${table} FROM STDIN WITH (FORMAT csv, DELIMITER '|');"
}

placement_tables() {
    local placement="$1"
    local database="$2"
    case "${placement}:${database}" in
        v0:db1) printf '%s\n' region nation supplier customer orders lineitem ;;
        v0:db2) printf '%s\n' part partsupp ;;
        v1:db1) printf '%s\n' region nation supplier customer part partsupp ;;
        v1:db2) printf '%s\n' orders lineitem ;;
        v2:db1) printf '%s\n' part partsupp orders lineitem ;;
        v2:db2) printf '%s\n' region nation supplier customer ;;
        *) die "Unknown placement mapping: ${placement}:${database}" ;;
    esac
}

collect_statistics() {
    local container="$1"
    local host="$2"
    log "Collecting PostgreSQL statistics in $container"
    docker exec "$ACCIO_CONTAINER" python workload/prepare/postgres.py \
        --url "postgresql://${PG_USER}:${PG_PASSWORD}@${host}:5432/${PG_DATABASE}" \
        --stats 100 \
        --seed 42
}

place_tables() {
    local placement="$1"
    validate_placement "$placement"
    require_tpch_data
    require_running_stack
    rm -f "$STATE_DIR/placement"

    reset_schema "$PG1_CONTAINER"
    reset_schema "$PG2_CONTAINER"

    local table
    while IFS= read -r table; do
        load_table "$PG1_CONTAINER" "$table"
    done < <(placement_tables "$placement" db1)
    while IFS= read -r table; do
        load_table "$PG2_CONTAINER" "$table"
    done < <(placement_tables "$placement" db2)

    collect_statistics "$PG1_CONTAINER" "$PG1_CONTAINER"
    collect_statistics "$PG2_CONTAINER" "$PG2_CONTAINER"
    printf '%s\n' "$placement" >"$STATE_DIR/placement"
    log "Loaded physical placement $placement"
}

run_benchmark() {
    local placement="$1"
    local query="${2:-}"
    validate_placement "$placement"
    require_running_stack

    local loaded=""
    [ ! -f "$STATE_DIR/placement" ] || loaded="$(<"$STATE_DIR/placement")"
    [ "$loaded" = "$placement" ] || die "Placement $placement is not loaded (loaded: ${loaded:-none}); run '$0 place $placement'"

    local workload="workload/tpch2_${placement}"
    local -a query_args=()
    local result_name="${placement}-all"
    if [ -n "$query" ]; then
        query_args=(--query "$query")
        result_name="${placement}-${query}"
    fi
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local result_file="$RESULTS_DIR/${result_name}-${timestamp}.log"

    log "Running $workload ${query:+query $query}; output: $result_file"
    docker exec "$ACCIO_CONTAINER" python benchmark/bench_duckdb.py accio \
        --config /experiment/config \
        --workload "$workload" \
        --strategy "$ACCIO_STRATEGY" \
        --runs "$ACCIO_RUNS" \
        --cores "$ACCIO_CORES" \
        --memory "$ACCIO_MEMORY" \
        --dbfile "/tmp/${result_name}.duckdb" \
        "${query_args[@]}" \
        db1 db2 2>&1 | tee "$result_file"
}

run_experiment() {
    local placement="$1"
    local query="${2:-}"
    up_stack
    place_tables "$placement"
    run_benchmark "$placement" "$query"
}

run_all() {
    local query="${1:-}"
    local placement
    up_stack
    for placement in v0 v1 v2; do
        place_tables "$placement"
        run_benchmark "$placement" "$query"
    done
}

show_status() {
    require_docker
    docker ps --all --filter "name=${PROJECT_NAME}-" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    if [ -f "$STATE_DIR/placement" ]; then
        log "Loaded placement: $(<"$STATE_DIR/placement")"
    else
        log "Loaded placement: none"
    fi
    local container
    for container in "$PG1_CONTAINER" "$PG2_CONTAINER"; do
        if container_running "$container"; then
            log "$container traffic control: $(docker exec "$container" tc qdisc show dev eth0)"
        fi
    done
}

down_stack() {
    require_docker
    local container
    for container in "$ACCIO_CONTAINER" "$PG1_CONTAINER" "$PG2_CONTAINER"; do
        if container_exists "$container"; then
            docker rm --force "$container" >/dev/null
            log "Removed container $container"
        fi
    done
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        docker network rm "$NETWORK_NAME" >/dev/null
        log "Removed network $NETWORK_NAME"
    fi
}

destroy_stack() {
    down_stack
    local volume
    for volume in "${PROJECT_NAME}-pg1-data" "${PROJECT_NAME}-pg2-data"; do
        if docker volume inspect "$volume" >/dev/null 2>&1; then
            docker volume rm "$volume" >/dev/null
        fi
    done
    rm -f "$STATE_DIR/placement"
    log "Removed PostgreSQL data volumes"
}

main() {
    local command="${1:-help}"
    case "$command" in
        build) build_images ;;
        up) up_stack ;;
        place) place_tables "${2:-}" ;;
        run) run_benchmark "${2:-}" "${3:-}" ;;
        experiment) run_experiment "${2:-}" "${3:-}" ;;
        all) run_all "${2:-}" ;;
        status) show_status ;;
        down) down_stack ;;
        destroy) destroy_stack ;;
        help|-h|--help) usage ;;
        *) usage >&2; die "Unknown command: $command" ;;
    esac
}

main "$@"
