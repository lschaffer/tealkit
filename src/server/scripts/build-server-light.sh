#!/usr/bin/env bash
# Build TealKit Server Light from the unified `server/` package (no llamadart).
# Keeps full SQLite + FTS5 + RAG + Scheduler + PDF/Excel/File tools; disables only embedded GGUF.
#
# Usage:
#   ./server/scripts/build-server-light.sh [output_path]
#   ./server/scripts/build-server-light.sh dist/tealkit_server_light

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_PATH="${1:-$SERVER_DIR/dist/tealkit_server_light}"

OVERRIDES_FILE="$SERVER_DIR/pubspec_overrides.yaml"
BACKUP_FILE="$SERVER_DIR/pubspec_overrides.yaml.bak.$$"
HAD_OVERRIDES=0

cleanup() {
  if [[ "$HAD_OVERRIDES" == "1" && -f "$BACKUP_FILE" ]]; then
    mv -f "$BACKUP_FILE" "$OVERRIDES_FILE"
  else
    rm -f "$OVERRIDES_FILE"
  fi
  (cd "$SERVER_DIR" && dart pub get >/dev/null 2>&1 || true)
}
trap cleanup EXIT

if [[ -f "$OVERRIDES_FILE" ]]; then
  cp "$OVERRIDES_FILE" "$BACKUP_FILE"
  HAD_OVERRIDES=1
fi

cat > "$OVERRIDES_FILE" <<'EOF'
dependency_overrides:
  llamadart:
    path: ../third_party/llamadart_stub
  dart_duckdb:
    path: ../third_party/dart_duckdb_light
  sqlite_vector:
    path: ../third_party/sqlite_vector_stub
EOF

mkdir -p "$(dirname "$OUT_PATH")"
cd "$SERVER_DIR"

echo "==> Resolving Light server dependencies (llamadart stubbed)..."
dart pub get

echo "==> Compiling TealKit Server Light (-DTEALKIT_LIGHT=true)..."
dart compile exe bin/tealkit_server.dart -DTEALKIT_LIGHT=true -o "$OUT_PATH"

echo "[OK] Built TealKit Server Light: $OUT_PATH"
