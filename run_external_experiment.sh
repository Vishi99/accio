#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${ACCIO_ENV_FILE:-${SCRIPT_DIR}/docker/experiment.env}"

die() {
    printf '[accio-external] ERROR: %s\n' "$*" >&2
    exit 1
}

[ -f "$ENV_FILE" ] || die "Missing $ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

[ -n "${ACCIO_COORDINATOR_IMAGE:-}" ] || die "ACCIO_COORDINATOR_IMAGE is not set"
[ -n "${ACCIO_RESULTS_DIR:-}" ] || die "ACCIO_RESULTS_DIR is not set"
case "$ACCIO_RESULTS_DIR" in
    /*) ;;
    *) die "ACCIO_RESULTS_DIR must be an absolute path" ;;
esac
mkdir -p "$ACCIO_RESULTS_DIR"

docker image inspect "$ACCIO_COORDINATOR_IMAGE" >/dev/null 2>&1 || \
    die "Coordinator image is not present locally: $ACCIO_COORDINATOR_IMAGE"

sources="${ACCIO_SOURCES:-db1 db2}"
[ -n "$sources" ] || die "ACCIO_SOURCES must contain at least one source"
seen_sources=" "
for source in $sources; do
    if ! [[ "$source" =~ ^[a-z][a-z0-9_]*$ ]]; then
        die "Invalid source name: $source"
    fi
    case "$seen_sources" in
        *" $source "*) die "Duplicate source in ACCIO_SOURCES: $source" ;;
        *) seen_sources="${seen_sources}${source} " ;;
    esac
    prefix="$(printf '%s' "$source" | tr '[:lower:]' '[:upper:]')"
    type_variable="${prefix}_TYPE"
    host_variable="${prefix}_HOST"
    port_variable="${prefix}_PORT"
    source_type="${!type_variable:-unknown}"
    host="${!host_variable:-}"
    port="${!port_variable:-}"
    [ -n "$host" ] || die "$host_variable is not set"
    [ -n "$port" ] || die "$port_variable is not set"
    printf '[accio-external] source %s -> %s:%s (%s)\n' \
        "$source" "$host" "$port" "$source_type"
done

coordinator_tables="${ACCIO_TABLES_COORDINATOR:-${TPCH_TABLES_COORDINATOR:-}}"
coordinator_data_dir="${ACCIO_DATA_DIR_COORDINATOR:-${TPCH_DATA_DIR_COORDINATOR:-}}"
volume_args=(--volume "$ACCIO_RESULTS_DIR:/experiment/results")
if [ -n "$coordinator_tables" ]; then
    [ -n "$coordinator_data_dir" ] || \
        die "ACCIO_DATA_DIR_COORDINATOR is required when coordinator tables are configured"
    [ -d "$coordinator_data_dir" ] || \
        die "Coordinator data directory does not exist: $coordinator_data_dir"
    case "$coordinator_data_dir" in
        /*) ;;
        *) die "ACCIO_DATA_DIR_COORDINATOR must be an absolute path" ;;
    esac
    volume_args+=(--volume "$coordinator_data_dir:/benchmark-data:ro")
fi

env_args=()
while IFS= read -r key; do
    env_args+=(--env "$key")
done < <(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$ENV_FILE")

printf '[accio-external] results: %s\n' "$ACCIO_RESULTS_DIR"

exec docker run --rm \
    --name "${STACK_NAME:-accio-tpch}-coordinator-run" \
    --network host \
    "${env_args[@]}" \
    --env ACCIO_DATA_MOUNT=/benchmark-data \
    "${volume_args[@]}" \
    "$ACCIO_COORDINATOR_IMAGE" \
    python /opt/accio/docker/coordinator/run_experiment.py
