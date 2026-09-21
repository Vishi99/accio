#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.multinode.yml"
ENV_FILE="${ACCIO_ENV_FILE:-${SCRIPT_DIR}/docker/experiment.env}"

usage() {
    cat <<'EOF'
Deploy a DuckDB/Accio coordinator with environment-configured TPC-H sources.

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
for one Docker host or DEPLOY_MODE=swarm for five labeled Swarm nodes.

Commands:
  config  Render and validate the fully interpolated Compose/Stack definition.
  build   Build locally, or build and push registry images in Swarm mode.
  deploy  Start the sources and submit the one-shot coordinator experiment.
  fresh   Compose only: delete all configured source volumes, then deploy.
  logs    Follow the coordinator output.
  rerun   Submit the coordinator experiment again without reloading sources.
  status  Show container/service state.
  down    Remove the deployment, retaining source volumes and host result logs.
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
    ACCIO_ENV_FILE="$ENV_FILE"
    export DEPLOY_MODE STACK_NAME NETWORK_DRIVER ACCIO_ENV_FILE
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed"
    docker info >/dev/null 2>&1 || die "Docker is installed, but its daemon is unavailable"
}

compose() {
    docker compose --env-file "$ENV_FILE" --file "$COMPOSE_FILE" --project-name "$STACK_NAME" "$@"
}

sources() {
    printf '%s\n' ${ACCIO_SOURCES:-db1 db2 db3 db4}
}

source_variable() {
    local prefix variable
    prefix="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    variable="${prefix}_$2"
    printf '%s\n' "${!variable:-}"
}

source_type() {
    local value
    value="$(source_variable "$1" TYPE)"
    printf '%s\n' "${value:-POSTGRES}" | tr '[:lower:]' '[:upper:]'
}

source_service() {
    local source="$1" configured suffix prefix
    configured="$(source_variable "$source" SERVICE)"
    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return
    fi
    suffix="${source#db}"
    prefix="$(printf '%s' "$source" | tr '[:lower:]' '[:upper:]')"
    case "$(source_type "$source")" in
        POSTGRES) printf 'postgres%s\n' "$suffix" ;;
        DUCKDB|QUACK) printf 'duckdb%s\n' "$suffix" ;;
        DATAFUSION) printf 'datafusion%s\n' "$suffix" ;;
        *) die "Set ${prefix}_SERVICE for custom source type $(source_type "$source")" ;;
    esac
}

validate_table_distribution() {
    local coordinator_tables="${TPCH_TABLES_COORDINATOR:-}"

    local seen=" "
    local source table tables
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

    for source in $(sources); do
        tables="$(configured_tables_for "$source")"
        for table in $tables; do
            case " region nation supplier customer part partsupp orders lineitem " in
                *" $table "*) ;;
                *) die "Unknown table in custom distribution: $table" ;;
            esac
            case "$seen" in
                *" $table "*) die "Table occurs more than once in custom distribution: $table" ;;
                *) seen="${seen}${table} " ;;
            esac
        done
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
        *) printf '%s\n' "" ;;
    esac
}

configured_tables_for() {
    local target="$1"
    local override="" variable prefix
    local table
    if [ "$target" = coordinator ]; then
        printf '%s\n' "${TPCH_TABLES_COORDINATOR:-}"
        return
    fi
    prefix="$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]')"
    variable="TPCH_TABLES_${prefix}"
    override="${!variable:-}"
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
    local target data_dir table variable prefix
    for target in $(sources) coordinator; do
        if [ "$target" = coordinator ]; then
            data_dir="$TPCH_DATA_DIR_COORDINATOR"
        else
            prefix="$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]')"
            variable="TPCH_DATA_DIR_${prefix}"
            data_dir="${!variable:-}"
        fi
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
    [ -n "${TPCH_DATA_DIR_COORDINATOR:-}" ] || die "TPCH_DATA_DIR_COORDINATOR must be set"
    [ -n "${ACCIO_RESULTS_DIR:-}" ] || die "ACCIO_RESULTS_DIR must be set"
    local source type data_dir variable prefix token seen_sources=" "
    for source in $(sources); do
        [[ "$source" =~ ^[a-z][a-z0-9_]*$ ]] || \
            die "ACCIO_SOURCES entries must be lowercase identifiers (got: $source)"
        [ "$source" != coordinator ] || die "coordinator is a reserved source name"
        case "$seen_sources" in
            *" $source "*) die "ACCIO_SOURCES contains duplicate source $source" ;;
            *) seen_sources="${seen_sources}${source} " ;;
        esac
        type="$(source_type "$source")"
        prefix="$(printf '%s' "$source" | tr '[:lower:]' '[:upper:]')"
        variable="TPCH_DATA_DIR_${prefix}"
        data_dir="${!variable:-}"
        [ -n "$data_dir" ] || die "$variable must be set"
        case "$data_dir" in /*) ;; *) die "$variable must be an absolute path" ;; esac
        case "$type" in
            POSTGRES) [ -n "$(source_variable "$source" PASSWORD)${POSTGRES_PASSWORD:-}" ] || die "Set ${prefix}_PASSWORD or POSTGRES_PASSWORD" ;;
            DUCKDB|QUACK)
                token="$(source_variable "$source" TOKEN)${QUACK_TOKEN:-}"
                [ -n "$token" ] || die "Set ${prefix}_TOKEN or QUACK_TOKEN"
                [ "${#token}" -ge 4 ] || die "${prefix}_TOKEN/QUACK_TOKEN must have at least four characters"
                ;;
            DATAFUSION) ;;
            *) die "${prefix}_TYPE must be POSTGRES, DUCKDB, QUACK, or DATAFUSION (got: $type)" ;;
        esac
    done
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
        case "${ACCIO_DUCKDB_IMAGE:-}" in
            */*) ;;
            *) die "Use a registry-qualified ACCIO_DUCKDB_IMAGE in Swarm mode" ;;
        esac
        case "${ACCIO_DATAFUSION_IMAGE:-}" in
            */*) ;;
            *) die "Use a registry-qualified ACCIO_DATAFUSION_IMAGE in Swarm mode" ;;
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
        --tag "$ACCIO_DUCKDB_IMAGE" \
        --build-arg "DUCKDB_VERSION=${DUCKDB_VERSION:-1.5.3}" \
        --file "$SCRIPT_DIR/docker/duckdb/Dockerfile" \
        "$SCRIPT_DIR"
    docker build \
        --tag "$ACCIO_DATAFUSION_IMAGE" \
        --file "$SCRIPT_DIR/docker/datafusion/Dockerfile" \
        "$SCRIPT_DIR"
    docker build \
        --tag "$ACCIO_COORDINATOR_IMAGE" \
        --build-arg "DUCKDB_VERSION=${DUCKDB_VERSION:-1.5.3}" \
        --build-arg "POSTGRESSCANNER_REPOSITORY=${POSTGRESSCANNER_REPOSITORY:-https://github.com/wangxiaoying/postgresscanner.git}" \
        --build-arg "POSTGRESSCANNER_REF=${POSTGRESSCANNER_REF:-prallel_query}" \
        --build-arg "POSTGRESSCANNER_BUILD_JOBS=${POSTGRESSCANNER_BUILD_JOBS:-4}" \
        --file "$SCRIPT_DIR/${ACCIO_COORDINATOR_DOCKERFILE:-docker/coordinator/Dockerfile}" \
        "$SCRIPT_DIR"
    docker push "$ACCIO_POSTGRES_IMAGE"
    docker push "$ACCIO_DUCKDB_IMAGE"
    docker push "$ACCIO_DATAFUSION_IMAGE"
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

    local source service destination
    local -a services=()
    for source in $(sources); do
        services+=("$(source_service "$source")")
    done
    compose create "${services[@]}" >/dev/null

    local container_id volume seen=" "
    local -a volumes=()
    for source in $(sources); do
        service="$(source_service "$source")"
        container_id="$(compose ps --all --quiet "$service")"
        [ -n "$container_id" ] || \
            die "$service container could not be created before fresh"
        case "$(source_type "$source")" in
            POSTGRES) destination=/var/lib/postgresql/data ;;
            DUCKDB|QUACK) destination=/var/lib/duckdb ;;
            DATAFUSION) continue ;;
            *) die "fresh does not know the volume location for $source" ;;
        esac
        volume="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Name}}{{end}}{{end}}" "$container_id")"
        [ -n "$volume" ] || die "could not resolve the data volume for $service"
        case "$seen" in
            *" $volume "*) die "multiple sources unexpectedly use volume $volume" ;;
            *) seen="${seen}${volume} "; volumes+=("$volume") ;;
        esac
    done

    log "removing persistent source data volumes: ${volumes[*]}"
    compose down
    if [ "${#volumes[@]}" -gt 0 ]; then
        docker volume rm "${volumes[@]}"
    fi
    for volume in "${volumes[@]}"; do
        docker volume inspect "$volume" >/dev/null 2>&1 && \
            die "source data volume still exists after removal: $volume"
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
    log "deployment removed; source volumes and host result logs were retained"
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
