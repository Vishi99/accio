#!/usr/bin/env bash

set -Eeuo pipefail

readonly ALL_TPCH_TABLES="region nation supplier customer part partsupp orders lineitem"
readonly SOURCE_ID="${TPCH_SOURCE_ID:-}"
readonly DATA_DIR="${TPCH_DATA_MOUNT:-/tpch-data}"

log() {
    printf '[accio-postgres:%s] %s\n' "${SOURCE_ID:-unconfigured}" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# The legacy run_docker_experiments.sh loads tables after startup. In that mode
# TPCH_SOURCE_ID is deliberately absent, so this init hook must remain a no-op.
if [ -z "$SOURCE_ID" ]; then
    log "TPCH_SOURCE_ID is not set; skipping automatic TPC-H initialization"
    exit 0
fi

standard_tables() {
    case "${TPCH_PLACEMENT:-v1}:${SOURCE_ID}" in
        v0:db1) printf '%s\n' "region nation supplier customer orders lineitem" ;;
        v0:db2) printf '%s\n' "part partsupp" ;;
        v1:db1) printf '%s\n' "region nation supplier customer part partsupp" ;;
        v1:db2) printf '%s\n' "orders lineitem" ;;
        v2:db1) printf '%s\n' "part partsupp orders lineitem" ;;
        v2:db2) printf '%s\n' "region nation supplier customer" ;;
        *) die "TPCH_PLACEMENT must be v0, v1, or v2 and TPCH_SOURCE_ID must be db1 or db2" ;;
    esac
}

default_tables() {
    local table
    for table in $(standard_tables); do
        case " ${TPCH_TABLES_COORDINATOR:-} " in
            *" $table "*) ;;
            *) printf '%s\n' "$table" ;;
        esac
    done
}

configured_tables() {
    local override=""
    case "$SOURCE_ID" in
        db1) override="${TPCH_TABLES_DB1:-}" ;;
        db2) override="${TPCH_TABLES_DB2:-}" ;;
        *) die "TPCH_SOURCE_ID must be db1 or db2 (got: ${SOURCE_ID:-<empty>})" ;;
    esac

    if [ -n "$override" ]; then
        printf '%s\n' "$override"
    else
        default_tables
    fi
}

table_ddl() {
    case "$1" in
        region) printf '%s\n' 'CREATE TABLE region (r_regionkey INTEGER NOT NULL, r_name CHAR(25) NOT NULL, r_comment VARCHAR(152));' ;;
        nation) printf '%s\n' 'CREATE TABLE nation (n_nationkey INTEGER NOT NULL, n_name CHAR(25) NOT NULL, n_regionkey INTEGER NOT NULL, n_comment VARCHAR(152));' ;;
        supplier) printf '%s\n' 'CREATE TABLE supplier (s_suppkey BIGINT NOT NULL, s_name CHAR(25) NOT NULL, s_address VARCHAR(40) NOT NULL, s_nationkey INTEGER NOT NULL, s_phone CHAR(15) NOT NULL, s_acctbal NUMERIC(15,2) NOT NULL, s_comment VARCHAR(101) NOT NULL);' ;;
        customer) printf '%s\n' 'CREATE TABLE customer (c_custkey BIGINT NOT NULL, c_name VARCHAR(25) NOT NULL, c_address VARCHAR(40) NOT NULL, c_nationkey INTEGER NOT NULL, c_phone CHAR(15) NOT NULL, c_acctbal NUMERIC(15,2) NOT NULL, c_mktsegment CHAR(10) NOT NULL, c_comment VARCHAR(117) NOT NULL);' ;;
        part) printf '%s\n' 'CREATE TABLE part (p_partkey BIGINT NOT NULL, p_name VARCHAR(55) NOT NULL, p_mfgr CHAR(25) NOT NULL, p_brand CHAR(10) NOT NULL, p_type VARCHAR(25) NOT NULL, p_size INTEGER NOT NULL, p_container CHAR(10) NOT NULL, p_retailprice NUMERIC(15,2) NOT NULL, p_comment VARCHAR(23) NOT NULL);' ;;
        partsupp) printf '%s\n' 'CREATE TABLE partsupp (ps_partkey BIGINT NOT NULL, ps_suppkey BIGINT NOT NULL, ps_availqty INTEGER NOT NULL, ps_supplycost NUMERIC(15,2) NOT NULL, ps_comment VARCHAR(199) NOT NULL);' ;;
        orders) printf '%s\n' 'CREATE TABLE orders (o_orderkey BIGINT NOT NULL, o_custkey BIGINT NOT NULL, o_orderstatus CHAR(1) NOT NULL, o_totalprice NUMERIC(15,2) NOT NULL, o_orderdate DATE NOT NULL, o_orderpriority CHAR(15) NOT NULL, o_clerk CHAR(15) NOT NULL, o_shippriority INTEGER NOT NULL, o_comment VARCHAR(79) NOT NULL);' ;;
        lineitem) printf '%s\n' 'CREATE TABLE lineitem (l_orderkey BIGINT NOT NULL, l_partkey BIGINT NOT NULL, l_suppkey BIGINT NOT NULL, l_linenumber INTEGER NOT NULL, l_quantity NUMERIC(15,2) NOT NULL, l_extendedprice NUMERIC(15,2) NOT NULL, l_discount NUMERIC(15,2) NOT NULL, l_tax NUMERIC(15,2) NOT NULL, l_returnflag CHAR(1) NOT NULL, l_linestatus CHAR(1) NOT NULL, l_shipdate DATE NOT NULL, l_commitdate DATE NOT NULL, l_receiptdate DATE NOT NULL, l_shipinstruct CHAR(25) NOT NULL, l_shipmode CHAR(10) NOT NULL, l_comment VARCHAR(44) NOT NULL);' ;;
        *) die "Unknown TPC-H table: $1" ;;
    esac
}

is_known_table() {
    case " $ALL_TPCH_TABLES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

load_table() {
    local table="$1"
    local input_file="${DATA_DIR}/${table}.tbl"
    if [ ! -r "$input_file" ]; then
        log "contents visible under $DATA_DIR:"
        ls -la "$DATA_DIR" >&2 || true
        die "Missing or unreadable $input_file; check the bind source and host permissions"
    fi

    log "loading $table from $input_file"
    table_ddl "$table" | psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"
    sed 's/|$//' "$input_file" | psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        --command "COPY ${table} FROM STDIN WITH (FORMAT csv, DELIMITER '|');"
}

tables="$(configured_tables)"
case "${DB_STATS_TARGET:-100}" in
    ''|0|*[!0-9]*) die "DB_STATS_TARGET must be a positive integer" ;;
esac

for table in $tables; do
    is_known_table "$table" || die "Invalid table '$table'; valid tables: $ALL_TPCH_TABLES"
    load_table "$table"
done

psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set "placement=${TPCH_PLACEMENT:-custom}" \
    --set "source_id=$SOURCE_ID" \
    --set "table_list=$tables" \
    --set "scale=${TPCH_SCALE:-unknown}" \
    --set "stats_target=${DB_STATS_TARGET:-100}" <<'SQL'
SELECT setseed(1.0 / 42.0);
SET default_statistics_target = :stats_target;
ANALYZE;

BEGIN;
CREATE TABLE accio_dataset_metadata (
    placement TEXT NOT NULL,
    source_id TEXT NOT NULL,
    table_list TEXT NOT NULL,
    scale TEXT NOT NULL,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO accio_dataset_metadata (placement, source_id, table_list, scale)
VALUES (:'placement', :'source_id', :'table_list', :'scale');
ALTER TABLE accio_dataset_metadata SET (autovacuum_enabled = off);
COMMIT;
SQL

log "TPC-H initialization complete: $tables"
