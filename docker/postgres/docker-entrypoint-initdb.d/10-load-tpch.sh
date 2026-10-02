#!/usr/bin/env bash

set -Eeuo pipefail

readonly ALL_TPCH_TABLES="region nation supplier customer part partsupp orders lineitem"
readonly ALL_JOB_TABLES="aka_name aka_title cast_info char_name comp_cast_type company_name company_type complete_cast info_type keyword kind_type link_type movie_companies movie_info movie_info_idx movie_keyword movie_link name person_info role_type title"
readonly DATASET="${ACCIO_DATASET:-tpch}"
readonly SOURCE_ID="${ACCIO_SOURCE_ID:-${TPCH_SOURCE_ID:-}}"
readonly DATA_DIR="${ACCIO_DATA_MOUNT:-${TPCH_DATA_MOUNT:-/benchmark-data}}"
readonly PLACEMENT="${ACCIO_DATASET_VARIANT:-${TPCH_PLACEMENT:-v1}}"
readonly DATASET_SIGNATURE="$([ "$DATASET" = tpch ] && printf '%s' "${TPCH_SCALE:-1}" || printf '%s' "${ACCIO_DATASET_VERSION:-job}")"

log() {
    printf '[accio-postgres:%s] %s\n' "${SOURCE_ID:-unconfigured}" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# The legacy runner loads tables after startup. In that mode the source id is
# deliberately absent, so this init hook must remain a no-op.
if [ -z "$SOURCE_ID" ]; then
    log "ACCIO_SOURCE_ID is not set; skipping automatic initialization"
    exit 0
fi

if ! [[ "$SOURCE_ID" =~ ^[a-z][a-z0-9_]*$ ]]; then
    die "ACCIO_SOURCE_ID must be a lowercase identifier (got: $SOURCE_ID)"
fi

case "$DATASET" in
    tpch|job) ;;
    *) die "ACCIO_DATASET must be tpch or job (got: $DATASET)" ;;
esac

standard_tables() {
    case "$PLACEMENT" in
        v0|v1|v2) ;;
        *) die "ACCIO_DATASET_VARIANT must be v0, v1, or v2" ;;
    esac
    case "${DATASET}:${PLACEMENT}:${SOURCE_ID}" in
        tpch:v0:db1) printf '%s\n' "region nation supplier customer orders lineitem" ;;
        tpch:v0:db2) printf '%s\n' "part partsupp" ;;
        tpch:v1:db1) printf '%s\n' "region nation supplier customer part partsupp" ;;
        tpch:v1:db2) printf '%s\n' "orders lineitem" ;;
        tpch:v2:db1) printf '%s\n' "part partsupp orders lineitem" ;;
        tpch:v2:db2) printf '%s\n' "region nation supplier customer" ;;
        job:v0:db1) printf '%s\n' "aka_name cast_info char_name comp_cast_type complete_cast info_type link_type movie_info movie_info_idx movie_link name person_info role_type title" ;;
        job:v0:db2) printf '%s\n' "aka_title company_name company_type keyword kind_type movie_companies movie_keyword" ;;
        job:v1:db1) printf '%s\n' "aka_name aka_title comp_cast_type company_name company_type complete_cast keyword kind_type link_type movie_companies movie_info movie_info_idx movie_keyword movie_link title" ;;
        job:v1:db2) printf '%s\n' "cast_info char_name info_type name person_info role_type" ;;
        job:v2:db1) printf '%s\n' "comp_cast_type complete_cast link_type movie_info movie_info_idx movie_link title" ;;
        job:v2:db2) printf '%s\n' "aka_name aka_title cast_info char_name company_name company_type info_type keyword kind_type movie_companies movie_keyword name person_info role_type" ;;
        *) printf '%s\n' "" ;;
    esac
}

default_tables() {
    local table
    for table in $(standard_tables); do
        case " ${ACCIO_TABLES_COORDINATOR:-${TPCH_TABLES_COORDINATOR:-}} " in
            *" $table "*) ;;
            *) printf '%s\n' "$table" ;;
        esac
    done
}

configured_tables() {
    local prefix variable legacy_variable override
    prefix="$(printf '%s' "$SOURCE_ID" | tr '[:lower:]' '[:upper:]')"
    variable="ACCIO_TABLES_${prefix}"
    legacy_variable="TPCH_TABLES_${prefix}"
    override="${!variable:-}"
    [ -n "$override" ] || override="${!legacy_variable:-}"

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
    local known_tables="$ALL_TPCH_TABLES"
    [ "$DATASET" = job ] && known_tables="$ALL_JOB_TABLES"
    case " $known_tables " in
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

job_files() {
    local table="$1" root file
    for root in "$DATA_DIR" "$DATA_DIR/csv"; do
        file="$root/$table.csv"
        if [ -r "$file" ]; then
            printf '%s\n' "$file"
            return
        fi
        if [ -d "$root/$table" ]; then
            find "$root/$table" -maxdepth 1 -type f -name '*.csv' -print | sort
            return
        fi
    done
}

prepare_job_schema() {
    local table tables="$1"
    psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        --file /opt/accio/job-schema.sql
    for table in $ALL_JOB_TABLES; do
        case " $tables " in
            *" $table "*) ;;
            *) psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
                --command "DROP TABLE \"$table\"" >/dev/null ;;
        esac
    done
}

load_job_table() {
    local table="$1" file found=false
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        found=true
        log "loading $table from $file"
        psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
            --command "COPY \"$table\" FROM STDIN WITH (FORMAT csv, DELIMITER ',', QUOTE '\"', ESCAPE E'\\\\', NULL '')" \
            < "$file"
    done < <(job_files "$table")
    [ "$found" = true ] || die "Missing $table.csv or $table/*.csv under $DATA_DIR or $DATA_DIR/csv"
}

tables="$(configured_tables)"
case "${DB_STATS_TARGET:-100}" in
    ''|0|*[!0-9]*) die "DB_STATS_TARGET must be a positive integer" ;;
esac

if [ "$DATASET" = job ]; then
    prepare_job_schema "$tables"
fi

for table in $tables; do
    is_known_table "$table" || die "Invalid $DATASET table '$table'"
    if [ "$DATASET" = job ]; then
        load_job_table "$table"
    else
        load_table "$table"
    fi
done

psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set "placement=$PLACEMENT" \
    --set "source_id=$SOURCE_ID" \
    --set "table_list=$tables" \
    --set "scale=$DATASET_SIGNATURE" \
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

log "$DATASET initialization complete: $tables"
