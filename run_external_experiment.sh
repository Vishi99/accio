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
[ -d "${TPCH_DATA_DIR_COORDINATOR:-}" ] || \
    die "Coordinator data directory does not exist: ${TPCH_DATA_DIR_COORDINATOR:-<unset>}"
[ -n "${ACCIO_RESULTS_DIR:-}" ] || die "ACCIO_RESULTS_DIR is not set"
mkdir -p "$ACCIO_RESULTS_DIR"

docker image inspect "$ACCIO_COORDINATOR_IMAGE" >/dev/null 2>&1 || \
    die "Coordinator image is not present locally: $ACCIO_COORDINATOR_IMAGE"

env_args=()
while IFS= read -r key; do
    env_args+=(--env "$key")
done < <(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$ENV_FILE")

printf '[accio-external] running coordinator against db1=%s:%s db3=%s:%s db4=%s:%s\n' \
    "$DB1_HOST" "$DB1_PORT" "$DB3_HOST" "$DB3_PORT" "$DB4_HOST" "$DB4_PORT"

exec docker run --rm \
    --name "${STACK_NAME:-accio-tpch}-coordinator-run" \
    --network host \
    "${env_args[@]}" \
    --volume "$ACCIO_RESULTS_DIR:/experiment/results" \
    --volume "$TPCH_DATA_DIR_COORDINATOR:/tpch-data:ro" \
    "$ACCIO_COORDINATOR_IMAGE" \
    python /opt/accio/docker/coordinator/run_experiment.py
