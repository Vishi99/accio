#!/usr/bin/env bash

set -Eeuo pipefail

if [ "${BANDWIDTH:-none}" != "none" ]; then
    echo "[accio-postgres] limiting eth0 egress to ${BANDWIDTH}"
    tc qdisc replace dev eth0 root netem rate "$BANDWIDTH"
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"
