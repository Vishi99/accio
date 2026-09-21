#!/usr/bin/env bash

set -Eeuo pipefail

readonly SOURCE_ID="${TPCH_SOURCE_ID:-}"

log() {
    printf '[accio-datafusion:%s] %s\n' "${SOURCE_ID:-unconfigured}" "$*"
}

if [ "${BANDWIDTH:-none}" != "none" ]; then
    log "limiting eth0 egress to ${BANDWIDTH}"
    tc qdisc replace dev eth0 root netem rate "$BANDWIDTH"
fi

exec /usr/local/bin/accio-datafusion-source
