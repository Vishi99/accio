#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TPCH_KIT_DIR="${TPCH_KIT_DIR:-${SCRIPT_DIR}/.accio-docker/tpch-kit}"
readonly TPCH_REPOSITORY="${TPCH_REPOSITORY:-https://github.com/gregrahn/tpch-kit.git}"
readonly TABLES="region nation supplier customer part partsupp orders lineitem"

SCALE="${1:-${TPCH_SCALE:-1}}"
OUTPUT_DIR="${2:-${TPCH_OUTPUT_DIR:-${SCRIPT_DIR}/.accio-docker/tpch-data/sf${SCALE}}}"

die() {
    printf '[tpch-dbgen] ERROR: %s\n' "$*" >&2
    exit 1
}

case "$SCALE" in
    1|10|50) ;;
    *) die "Scale must be 1, 10, or 50 (got: $SCALE)" ;;
esac

for command in git make cc; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

if [ ! -d "$TPCH_KIT_DIR/.git" ]; then
    printf '[tpch-dbgen] Cloning %s into %s\n' "$TPCH_REPOSITORY" "$TPCH_KIT_DIR"
    mkdir -p "$(dirname "$TPCH_KIT_DIR")"
    git clone "$TPCH_REPOSITORY" "$TPCH_KIT_DIR"
fi

printf '[tpch-dbgen] Building dbgen\n'
make -C "$TPCH_KIT_DIR/dbgen" MACHINE=LINUX DATABASE=POSTGRESQL

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

printf '[tpch-dbgen] Generating TPC-H SF%s in %s\n' "$SCALE" "$OUTPUT_DIR"
(
    cd "$TPCH_KIT_DIR/dbgen"
    DSS_PATH="$OUTPUT_DIR" ./dbgen -s "$SCALE" -f
)

for table in $TABLES; do
    [ -s "$OUTPUT_DIR/${table}.tbl" ] || die "Missing generated file: $OUTPUT_DIR/${table}.tbl"
done

printf '[tpch-dbgen] Done: %s\n' "$(du -sh "$OUTPUT_DIR" | awk '{print $1}')"
cat <<EOF

Use these settings in docker/experiment.env:

TPCH_SCALE=${SCALE}
TPCH_DATA_DIR_DB1=${OUTPUT_DIR}
TPCH_DATA_DIR_DB2=${OUTPUT_DIR}
TPCH_DATA_DIR_COORDINATOR=${OUTPUT_DIR}
EOF
