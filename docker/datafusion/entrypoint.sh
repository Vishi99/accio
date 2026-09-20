#!/usr/bin/env bash

set -Eeuo pipefail

readonly ALL_TPCH_TABLES="region nation supplier customer part partsupp orders lineitem"
readonly SOURCE_ID="${TPCH_SOURCE_ID:-}"
readonly DATA_DIR="${TPCH_DATA_MOUNT:-/tpch-data}"
readonly DATABASE="${DATAFUSION_DATABASE:-postgres}"
server_pid=""

log() {
    printf '[accio-datafusion:%s] %s\n' "${SOURCE_ID:-unconfigured}" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

stop_server() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid"
        wait "$server_pid" || true
    fi
}

trap stop_server EXIT INT TERM

is_known_table() {
    case " $ALL_TPCH_TABLES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

table_columns() {
    case "$1" in
        region) printf '%s\n' 'r_regionkey INTEGER, r_name VARCHAR, r_comment VARCHAR, _accio_trailing VARCHAR' ;;
        nation) printf '%s\n' 'n_nationkey INTEGER, n_name VARCHAR, n_regionkey INTEGER, n_comment VARCHAR, _accio_trailing VARCHAR' ;;
        supplier) printf '%s\n' 's_suppkey BIGINT, s_name VARCHAR, s_address VARCHAR, s_nationkey INTEGER, s_phone VARCHAR, s_acctbal DECIMAL(15,2), s_comment VARCHAR, _accio_trailing VARCHAR' ;;
        customer) printf '%s\n' 'c_custkey BIGINT, c_name VARCHAR, c_address VARCHAR, c_nationkey INTEGER, c_phone VARCHAR, c_acctbal DECIMAL(15,2), c_mktsegment VARCHAR, c_comment VARCHAR, _accio_trailing VARCHAR' ;;
        part) printf '%s\n' 'p_partkey BIGINT, p_name VARCHAR, p_mfgr VARCHAR, p_brand VARCHAR, p_type VARCHAR, p_size INTEGER, p_container VARCHAR, p_retailprice DECIMAL(15,2), p_comment VARCHAR, _accio_trailing VARCHAR' ;;
        partsupp) printf '%s\n' 'ps_partkey BIGINT, ps_suppkey BIGINT, ps_availqty INTEGER, ps_supplycost DECIMAL(15,2), ps_comment VARCHAR, _accio_trailing VARCHAR' ;;
        orders) printf '%s\n' 'o_orderkey BIGINT, o_custkey BIGINT, o_orderstatus VARCHAR, o_totalprice DECIMAL(15,2), o_orderdate DATE, o_orderpriority VARCHAR, o_clerk VARCHAR, o_shippriority INTEGER, o_comment VARCHAR, _accio_trailing VARCHAR' ;;
        lineitem) printf '%s\n' 'l_orderkey BIGINT, l_partkey BIGINT, l_suppkey BIGINT, l_linenumber INTEGER, l_quantity DECIMAL(15,2), l_extendedprice DECIMAL(15,2), l_discount DECIMAL(15,2), l_tax DECIMAL(15,2), l_returnflag VARCHAR, l_linestatus VARCHAR, l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE, l_shipinstruct VARCHAR, l_shipmode VARCHAR, l_comment VARCHAR, _accio_trailing VARCHAR' ;;
        *) die "Unknown TPC-H table: $1" ;;
    esac
}

[ -n "$SOURCE_ID" ] || die "TPCH_SOURCE_ID is required"
[[ "$SOURCE_ID" =~ ^[a-z][a-z0-9_]*$ ]] || \
    die "TPCH_SOURCE_ID must be a lowercase identifier (got: $SOURCE_ID)"

prefix="$(printf '%s' "$SOURCE_ID" | tr '[:lower:]' '[:upper:]')"
tables_variable="TPCH_TABLES_${prefix}"
tables="${!tables_variable:-}"

for table in $tables; do
    is_known_table "$table" || die "Invalid table '$table'; valid tables: $ALL_TPCH_TABLES"
    [ -r "$DATA_DIR/$table.tbl" ] || \
        die "Missing or unreadable $DATA_DIR/$table.tbl; check the bind source and host permissions"
done

if [ "${BANDWIDTH:-none}" != "none" ]; then
    log "limiting eth0 egress to ${BANDWIDTH}"
    tc qdisc replace dev eth0 root netem rate "$BANDWIDTH"
fi

datafusion-postgres-cli --host 0.0.0.0 -p 5432 &
server_pid="$!"

for _attempt in $(seq 1 60); do
    kill -0 "$server_pid" 2>/dev/null || die "datafusion-postgres-cli exited during startup"
    if pg_isready --host 127.0.0.1 --port 5432 --username postgres --dbname "$DATABASE" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
pg_isready --host 127.0.0.1 --port 5432 --username postgres --dbname "$DATABASE" >/dev/null 2>&1 || \
    die "DataFusion PGWire endpoint did not become ready"

for table in $tables; do
    input_file="$DATA_DIR/$table.tbl"
    columns="$(table_columns "$table")"
    log "registering external table $table from $input_file"
    psql --set ON_ERROR_STOP=1 \
        --host 127.0.0.1 --port 5432 --username postgres --dbname "$DATABASE" \
        --command "CREATE EXTERNAL TABLE \"$table\" ($columns) STORED AS CSV LOCATION '$input_file' OPTIONS ('format.delimiter' '|', 'has_header' 'false');"
done

# Use a new connection to verify that the server-wide catalog contains every
# table, rather than only the bootstrap connection's session.
for table in $tables; do
    psql --set ON_ERROR_STOP=1 \
        --host 127.0.0.1 --port 5432 --username postgres --dbname "$DATABASE" \
        --command "SELECT * FROM \"$table\" LIMIT 0;" >/dev/null
done

log "ready on port 5432 with tables: ${tables:-<none>}"
wait "$server_pid"
