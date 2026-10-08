#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly JOB_DATA_URL="${JOB_DATA_URL:-https://event.cwi.nl/da/job/imdb.tgz}"
readonly JOB_CACHE_DIR="${JOB_CACHE_DIR:-${SCRIPT_DIR}/.accio-docker/job}"
readonly TABLES="aka_name aka_title cast_info char_name comp_cast_type company_name company_type complete_cast info_type keyword kind_type link_type movie_companies movie_info movie_info_idx movie_keyword movie_link name person_info role_type title"

OUTPUT_DIR="${1:-${JOB_OUTPUT_DIR:-${SCRIPT_DIR}/data/job}}"
ARCHIVE="${JOB_CACHE_DIR}/imdb.tgz"
PARTIAL_ARCHIVE="${ARCHIVE}.part"
STAGING_DIR=""

die() {
    printf '[job-data] ERROR: %s\n' "$*" >&2
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<EOF
Download and prepare the JOB IMDb CSV snapshot.

Usage:
  ./prepare_job_data.sh [OUTPUT_DIR]

Defaults:
  OUTPUT_DIR    ${SCRIPT_DIR}/data/job
  archive cache ${JOB_CACHE_DIR}/imdb.tgz

Environment overrides:
  JOB_DATA_URL, JOB_CACHE_DIR, JOB_OUTPUT_DIR
EOF
    exit 0
fi

[ "$#" -le 1 ] || die "Usage: ./prepare_job_data.sh [OUTPUT_DIR]"

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT

for command in tar find mktemp mv chmod du; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

mkdir -p "$OUTPUT_DIR" "$JOB_CACHE_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

dataset_is_complete=true
for table in $TABLES; do
    if [ ! -s "$OUTPUT_DIR/${table}.csv" ]; then
        dataset_is_complete=false
        break
    fi
done

if [ "$dataset_is_complete" = true ]; then
    chmod a+rx "$OUTPUT_DIR"
    chmod a+r "$OUTPUT_DIR"/*.csv
    printf '[job-data] Reusing complete JOB dataset in %s\n' "$OUTPUT_DIR"
else
    archive_validated=false
    if [ -f "$ARCHIVE" ]; then
        if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
            archive_validated=true
        else
            invalid_archive="${ARCHIVE}.invalid.$(date -u +%Y%m%dT%H%M%SZ)"
            printf '[job-data] Cached archive is invalid; preserving it as %s\n' "$invalid_archive"
            mv "$ARCHIVE" "$invalid_archive"
        fi
    fi

    if [ ! -f "$ARCHIVE" ] && [ -f "$PARTIAL_ARCHIVE" ] \
        && tar -tzf "$PARTIAL_ARCHIVE" >/dev/null 2>&1; then
        printf '[job-data] Reusing completed partial download %s\n' "$PARTIAL_ARCHIVE"
        mv "$PARTIAL_ARCHIVE" "$ARCHIVE"
        archive_validated=true
    fi

    if [ ! -f "$ARCHIVE" ]; then
        printf '[job-data] Downloading %s (about 1.2 GB)\n' "$JOB_DATA_URL"
        if command -v curl >/dev/null 2>&1; then
            curl --fail --location --retry 5 --retry-delay 5 \
                --continue-at - --output "$PARTIAL_ARCHIVE" "$JOB_DATA_URL"
        elif command -v wget >/dev/null 2>&1; then
            wget --continue --output-document="$PARTIAL_ARCHIVE" "$JOB_DATA_URL"
        else
            die "Install curl or wget to download the JOB dataset"
        fi
        mv "$PARTIAL_ARCHIVE" "$ARCHIVE"
    else
        printf '[job-data] Reusing cached archive %s\n' "$ARCHIVE"
    fi

    if [ "$archive_validated" = false ]; then
        tar -tzf "$ARCHIVE" >/dev/null 2>&1 || \
            die "Downloaded archive is not a valid gzip tar archive: $ARCHIVE"
    fi
    STAGING_DIR="$(mktemp -d "${OUTPUT_DIR}.extract.XXXXXX")"
    printf '[job-data] Extracting archive\n'
    tar -xzf "$ARCHIVE" -C "$STAGING_DIR"

    for table in $TABLES; do
        source_file="$(find "$STAGING_DIR" -type f -name "${table}.csv" -print -quit)"
        [ -n "$source_file" ] || die "Archive does not contain ${table}.csv"
        [ -s "$source_file" ] || die "Archive contains an empty ${table}.csv"
    done

    for table in $TABLES; do
        source_file="$(find "$STAGING_DIR" -type f -name "${table}.csv" -print -quit)"
        mv -f "$source_file" "$OUTPUT_DIR/${table}.csv"
    done

    chmod a+rx "$OUTPUT_DIR"
    chmod a+r "$OUTPUT_DIR"/*.csv
fi

for table in $TABLES; do
    [ -s "$OUTPUT_DIR/${table}.csv" ] || die "Missing prepared file: $OUTPUT_DIR/${table}.csv"
done

printf '[job-data] Ready: %s (%s)\n' \
    "$OUTPUT_DIR" "$(du -sh "$OUTPUT_DIR" | awk '{print $1}')"
cat <<EOF

Use this path for the JOB source mounted on this host:

JOB_DATA_DIR=${OUTPUT_DIR}

For single-host Compose, set:

ACCIO_DATA_DIR_DB1=${OUTPUT_DIR}
ACCIO_DATA_DIR_DB3=${OUTPUT_DIR}
ACCIO_DATA_DIR_DB4=${OUTPUT_DIR}
ACCIO_DATA_DIR_COORDINATOR=${OUTPUT_DIR}
EOF
