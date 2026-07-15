#!/usr/bin/env sh
# entrypoint.sh — TealKit Server Docker entry point
# Creates required data subdirectories, then exec's the AOT binary.

set -e

DATA_DIR="${TEALKIT_DATA_DIR:-/data}"

mkdir -p \
    "${DATA_DIR}/db" \
    "${DATA_DIR}/output" \
    "${DATA_DIR}/logs"

exec /app/tealkit_server "$@"
