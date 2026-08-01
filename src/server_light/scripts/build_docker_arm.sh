#!/usr/bin/env bash
# Build script for TealKit Server Light using Docker.
# Cross-compiles a standalone native executable for ARM64/ARMv7 Linux.
#
# server_light uses stub packages for dart_duckdb and llamadart (see
# server_light/pubspec.yaml dependency_overrides), so no Flutter SDK
# and no native build hooks are needed.
#
# Usage:
#   ./build_docker_arm.sh [platform] [dart_version]
#   ./build_docker_arm.sh linux/arm/v7
#   ./build_docker_arm.sh linux/arm/v7 3.8.0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_LIGHT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$SERVER_LIGHT_DIR/.." && pwd)"

PLATFORM="${1:-linux/arm64}"
DART_TAG="${2:-stable}"
OUTPUT_DIR="$SERVER_LIGHT_DIR/dist"
OUTPUT_BIN="$OUTPUT_DIR/tealkit-server-light"

echo "================================================================="
echo " Building TealKit Server Light using Docker"
echo " Platform:    $PLATFORM"
echo " Dart image:  dart:$DART_TAG"
echo " Output:      $OUTPUT_BIN"
echo "================================================================="

mkdir -p "$OUTPUT_DIR"

docker run --rm \
  --platform "$PLATFORM" \
  -v "$PROJECT_DIR:/workspace" \
  -w /workspace/server_light \
  "dart:$DART_TAG" \
  sh -c "
    dart pub get && \
    dart compile exe bin/server_light.dart -o dist/tealkit-server-light
  " || {
    echo ""
    echo "ERROR: Docker build failed."
    echo "Alternative: build natively using scripts/build_arm_light.sh"
    exit 1
  }

echo "================================================================="
echo " Build Completed Successfully!"
echo " Binary: $OUTPUT_BIN"
ls -lh "$OUTPUT_BIN"
echo ""
echo " Copy to target device and run:"
echo "   scp $OUTPUT_BIN user@device:/opt/tealkit/"
echo "   /opt/tealkit/tealkit-server-light"
echo "================================================================="
