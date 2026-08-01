#!/usr/bin/env bash
# Build script for TealKit Server Light — native (local) compilation.
# Compiles a standalone native executable using dart compile exe.
# Stub packages for dart_duckdb and llamadart remove Flutter/native hook dependencies.
#
# For cross-compilation (ARM from x86_64), use build_docker_arm.sh instead.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_LIGHT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$SERVER_LIGHT_DIR/dist"
OUTPUT_BIN="$OUTPUT_DIR/tealkit-server-light"

echo "=== Building TealKit Server Light (Native) ==="
echo ""

cd "$SERVER_LIGHT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "[1/2] Resolving dependencies..."
dart pub get

echo "[2/2] Compiling $OUTPUT_BIN ..."
dart compile exe bin/server_light.dart -o "$OUTPUT_BIN" || {
  echo ""
  echo "ERROR: Compilation failed."
  echo "Try: dart run bin/server_light.dart (no compilation needed)"
  exit 1
}

echo ""
echo "Build succeeded!"
echo "Binary: $OUTPUT_BIN"
ls -lh "$OUTPUT_BIN"
echo ""
echo "Run: $OUTPUT_BIN"
