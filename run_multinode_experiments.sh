#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.multinode.yml"
ENV_FILE="${ACCIO_ENV_FILE:-${SCRIPT_DIR}/docker/experiment.env}"

usage() {
    cat <<'EOF'
Deploy DuckDB/Accio with three PostgreSQL TPC-H sources.

Usage:
  cp docker/experiment.env.example docker/experiment.env
  # edit docker/experiment.env, then:
  ./run_multinode_experiments.sh config
  ./run_multinode_experiments.sh build
  ./run_multinode_experiments.sh deploy
  ./run_multinode_experiments.sh fresh
  ./run_multinode_experiments.sh logs
  ./run_multinode_experiments.sh rerun
  ./run_multinode_experiments.sh status
  ./run_multinode_experiments.sh down

Select another file with ACCIO_ENV_FILE=/path/to/file. Set DEPLOY_MODE=compose
for one Docker host or DEPLOY_MODE=swarm for four labeled Swarm nodes.

Commands:
  config  Render and validate the fully interpolated Compose/Stack definition.
  build   Build locally, or build and push registry images in Swarm mode.
  deploy  Start the sources and submit the one-shot coordinator experiment.
  fresh   Compose only: delete all PostgreSQL volumes, then deploy from scratch.
  logs    Follow the coordinator output.
  rerun   Submit the coordinator experiment again without reloading PostgreSQL.
  status  Show container/service state.
  down    Remove the deployment, retaining PostgreSQL volumes and host result logs.
EOF
}

die() {
    printf '[accio-multinode] ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[accio-multinode] %s\n' "$*"
}

load_environment() {
    [ -f "$ENV_FILE" ] || die "Missing $ENV_FILE; copy docker/experiment.env.example and edit it"
    set -a
    # The env file is intentionally shell-compatible KEY=value configuration.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    DEPLOY_MODE="${DEPLOY_MODE:-compose}"
    STACK_NAME="${STACK_NAME:-accio-tpch}"
    case "$DEPLOY_MODE" in
        compose) NETWORK_DRIVER="${NETWORK_DRIVER:-bridge}" ;;
        swarm) NETWORK_DRIVER=overlay ;;
        *) die "DEPLOY_MODE must be compose or swarm (got: $DEPLOY_MODE)" ;;
    esac
    export DEPLOY_MODE STACK_NAME NETWORK_DRIVER
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed"
    docker info >/dev/null 2>&1 || die "Docker is installed, but its daemon is unavailable"
}

compose() {
    docker compose --env-file "$ENV_FILE" --file "$COMPOSE_FILE" --project-name "$STACK_NAME" "$@"
}

validate_table_distribution() {
    local db1_tables="${TPCH_TABLES_DB1:-}"
    local db2_tables="${TPCH_TABLES_DB2:-}"
    local db3_tables="${TPCH_TABLES_DB3:-}"
    local coordinator_tables="${TPCH_TABLES_COORDINATOR:-}"

    local seen=" "
    local table
    for table in $coordinator_tables; do
        case " region nation supplier customer part partsupp orders lineitem " in
            *" $table "*) ;;
            *) die "Unknown table in custom distribution: $table" ;;
        esac
        case "$seen" in
            *" $table "*) die "Table occurs more than once in custom distribution: $table" ;;
            *) seen="${seen}${table} " ;;
        esac
    done

    if [ -z "$db1_tables" ] && [ -z "$db2_tables" ] && [ -z "$db3_tables" ]; then
        return
    fi
    [ -n "$db1_tables" ] && [ -n "$db2_tables" ] || \
        die "Set TPCH_TABLES_DB1 and TPCH_TABLES_DB2 whenever any source override is used"

    for table in $db1_tables $db2_tables $db3_tables; do
        case " region nation supplier customer part partsupp orders lineitem " in
            *" $table "*) ;;
            *) die "Unknown table in custom distribution: $table" ;;
        esac
        case "$seen" in
            *" $table "*) die "Table occurs more than once in custom distribution: $table" ;;
            *) seen="${seen}${table} " ;;
        esac
    done
    for table in region nation supplier customer part partsupp orders lineitem; do
        case "$seen" in
            *" $table "*) ;;
            *) die "Table is missing from custom distribution: $table" ;;
        esac
    done
}

default_source_tables() {
    case "${TPCH_PLACEMENT}:${1}" in
        v0:db1) printf '%s\n' "region nation supplier customer orders lineitem" ;;
        v0:db2) printf '%s\n' "part partsupp" ;;
        v1:db1) printf '%s\n' "region nation supplier customer part partsupp" ;;
        v1:db2) printf '%s\n' "orders lineitem" ;;
        v2:db1) printf '%s\n' "part partsupp orders lineitem" ;;
        v2:db2) printf '%s\n' "region nation supplier customer" ;;
        v0:db3|v1:db3|v2:db3) printf '%s\n' "" ;;
        *) die "cannot resolve table distribution for ${TPCH_PLACEMENT}:${1}" ;;
    esac
}

configured_tables_for() {
    local target="$1"
    local override=""
    local table
    case "$target" in
        db1) override="${TPCH_TABLES_DB1:-}" ;;
        db2) override="${TPCH_TABLES_DB2:-}" ;;
        db3) override="${TPCH_TABLES_DB3:-}" ;;
        coordinator) printf '%s\n' "${TPCH_TABLES_COORDINATOR:-}"; return ;;
        *) die "unknown table target: $target" ;;
    esac
    if [ -n "$override" ]; then
        printf '%s\n' "$override"
        return
    fi
    for table in $(default_source_tables "$target"); do
        case " ${TPCH_TABLES_COORDINATOR:-} " in
            *" $table "*) ;;
            *) printf '%s\n' "$table" ;;
        esac
    done
}

validate_compose_data_files() {
    local target data_dir table
    for target in db1 db2 db3 coordinator; do
        case "$target" in
            db1) data_dir="$TPCH_DATA_DIR_DB1" ;;
            db2) data_dir="$TPCH_DATA_DIR_DB2" ;;
            db3) data_dir="$TPCH_DATA_DIR_DB3" ;;
            coordinator) data_dir="$TPCH_DATA_DIR_COORDINATOR" ;;
        esac
        [ -d "$data_dir" ] || die "TPC-H data directory for $target does not exist: $data_dir"
        for table in $(configured_tables_for "$target"); do
            [ -s "$data_dir/$table.tbl" ] || \
                die "Missing $data_dir/$table.tbl required by $target"
        done
    done
}

validate_inputs() {
    case "${TPCH_PLACEMENT:-}" in
        v0|v1|v2) ;;
        *) die "TPCH_PLACEMENT must be v0, v1, or v2" ;;
    esac
    case "${TPCH_SCALE:-}" in
        1|10|50) ;;
        *) die "TPCH_SCALE must be 1, 10, or 50" ;;
    esac
    [ -n "${POSTGRES_PASSWORD:-}" ] || die "POSTGRES_PASSWORD must not be empty"
    [ -n "${TPCH_DATA_DIR_DB1:-}" ] || die "TPCH_DATA_DIR_DB1 must be set"
    [ -n "${TPCH_DATA_DIR_DB2:-}" ] || die "TPCH_DATA_DIR_DB2 must be set"
    [ -n "${TPCH_DATA_DIR_DB3:-}" ] || die "TPCH_DATA_DIR_DB3 must be set"
    [ -n "${TPCH_DATA_DIR_COORDINATOR:-}" ] || die "TPCH_DATA_DIR_COORDINATOR must be set"
    [ -n "${ACCIO_RESULTS_DIR:-}" ] || die "ACCIO_RESULTS_DIR must be set"
    case "$TPCH_DATA_DIR_DB1" in
        /*) ;;
        *) die "TPCH_DATA_DIR_DB1 must be an absolute path" ;;
    esac
    case "$TPCH_DATA_DIR_DB2" in
        /*) ;;
        *) die "TPCH_DATA_DIR_DB2 must be an absolute path" ;;
    esac
    case "$TPCH_DATA_DIR_DB3" in
        /*) ;;
        *) die "TPCH_DATA_DIR_DB3 must be an absolute path" ;;
    esac
    case "$TPCH_DATA_DIR_COORDINATOR" in
        /*) ;;
        *) die "TPCH_DATA_DIR_COORDINATOR must be an absolute path" ;;
    esac
    case "$ACCIO_RESULTS_DIR" in
        /*) ;;
        *) die "ACCIO_RESULTS_DIR must be an absolute path" ;;
    esac
    validate_table_distribution

    if [ "$DEPLOY_MODE" = "compose" ]; then
        [ -d "$ACCIO_RESULTS_DIR" ] || \
            die "ACCIO_RESULTS_DIR does not exist; create it first: $ACCIO_RESULTS_DIR"
        validate_compose_data_files
    else
        case "${ACCIO_COORDINATOR_IMAGE:-}" in
            */*) ;;
            *) die "Use a registry-qualified ACCIO_COORDINATOR_IMAGE in Swarm mode" ;;
        esac
        case "${ACCIO_POSTGRES_IMAGE:-}" in
            */*) ;;
            *) die "Use a registry-qualified ACCIO_POSTGRES_IMAGE in Swarm mode" ;;
        esac
    fi
}

validate_config() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed"
    validate_inputs
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose config --quiet
    else
        docker stack config --compose-file "$COMPOSE_FILE" >/dev/null
    fi
    log "configuration is valid for $DEPLOY_MODE"
}

build_images() {
    require_docker
    validate_inputs
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose build
        return
    fi

    docker build \
        --tag "$ACCIO_POSTGRES_IMAGE" \
        --build-arg "POSTGRES_BASE_IMAGE=${POSTGRES_BASE_IMAGE:-postgres:16-bookworm}" \
        --file "$SCRIPT_DIR/docker/postgres/Dockerfile" \
        "$SCRIPT_DIR"
    docker build \
        --tag "$ACCIO_COORDINATOR_IMAGE" \
        --build-arg "POSTGRESSCANNER_REPOSITORY=${POSTGRESSCANNER_REPOSITORY:-https://github.com/wangxiaoying/postgresscanner.git}" \
        --build-arg "POSTGRESSCANNER_REF=${POSTGRESSCANNER_REF:-prallel_query}" \
        --build-arg "POSTGRESSCANNER_BUILD_JOBS=${POSTGRESSCANNER_BUILD_JOBS:-4}" \
        --file "$SCRIPT_DIR/docker/coordinator/Dockerfile" \
        "$SCRIPT_DIR"
    docker push "$ACCIO_POSTGRES_IMAGE"
    docker push "$ACCIO_COORDINATOR_IMAGE"
}

deploy() {
    require_docker
    validate_inputs
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose up --detach
    else
        [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" = true ] || \
            die "This Docker daemon is not an active Swarm manager"
        docker stack deploy --with-registry-auth --compose-file "$COMPOSE_FILE" "$STACK_NAME"
    fi
    log "deployment submitted; use '$0 logs' to follow the experiment"
}

fresh() {
    require_docker
    validate_inputs
    [ "$DEPLOY_MODE" = "compose" ] || \
        die "fresh is only available in Compose mode; Swarm volumes are node-local"

    # Create any missing source container (for example postgres3 after upgrading
    # an existing two-source deployment) so its actual Compose volume can be
    # resolved before all source volumes are removed.
    compose create postgres1 postgres2 postgres3 >/dev/null

    local service container_id volume seen=" "
    local -a volumes=()
    for service in postgres1 postgres2 postgres3; do
        container_id="$(compose ps -q "$service")"
        [ -n "$container_id" ] || \
            die "$service container could not be created before fresh"
        volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$container_id")"
        [ -n "$volume" ] || die "could not resolve the PostgreSQL data volume for $service"
        case "$seen" in
            *" $volume "*) die "multiple PostgreSQL services unexpectedly use volume $volume" ;;
            *) seen="${seen}${volume} "; volumes+=("$volume") ;;
        esac
    done

    log "removing PostgreSQL data volumes: ${volumes[*]}"
    compose down
    docker volume rm "${volumes[@]}"
    for volume in "${volumes[@]}"; do
        docker volume inspect "$volume" >/dev/null 2>&1 && \
            die "PostgreSQL data volume still exists after removal: $volume"
    done
    deploy
}

logs() {
    require_docker
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose ps --all
        compose logs --follow coordinator
    else
        docker service ps --no-trunc "${STACK_NAME}_coordinator"
        docker service logs --follow "${STACK_NAME}_coordinator"
    fi
}

rerun() {
    require_docker
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose run --rm coordinator
    else
        docker service update --force "${STACK_NAME}_coordinator" >/dev/null
        log "coordinator resubmitted; use '$0 logs' to follow it"
    fi
}

status() {
    require_docker
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose ps --all
    else
        docker stack services "$STACK_NAME"
        docker stack ps --no-trunc "$STACK_NAME"
    fi
}

down() {
    require_docker
    if [ "$DEPLOY_MODE" = "compose" ]; then
        compose down
    else
        docker stack rm "$STACK_NAME"
    fi
    log "deployment removed; PostgreSQL volumes and host result logs were retained"
}

main() {
    case "${1:-help}" in
        help|-h|--help) usage; return ;;
    esac
    load_environment
    case "${1:-help}" in
        config) validate_config ;;
        build) build_images ;;
        deploy) deploy ;;
        fresh) fresh ;;
        logs) logs ;;
        rerun) rerun ;;
        status) status ;;
        down) down ;;
        *) usage >&2; die "Unknown command: ${1:-}" ;;
    esac
}

main "$@"
