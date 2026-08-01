#!/usr/bin/env bash
# Package TealKit Server Light for deployment to ARM Linux devices.
# Creates a minimal tarball with source files + stub packages needed to
# compile a standalone native executable on the target.
#
# Usage:
#   bash server_light/scripts/package_light.sh
#
# Output: dist/tealkit_light_deploy.tar.gz

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_LIGHT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$SERVER_LIGHT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/dist"
PACKAGE_DIR="$OUTPUT_DIR/tealkit_light_deploy"
PACKAGE_TARBALL="$OUTPUT_DIR/tealkit_light_deploy.tar.gz"

echo "=== Packaging TealKit Server Light for Deployment ==="
echo ""

# Clean previous build (ignore errors on WSL2 /mnt/c/ due to Windows permissions)
rm -rf "$PACKAGE_DIR" "$PACKAGE_TARBALL" 2>/dev/null || true
# If rm failed, try with different approach
if [ -d "$PACKAGE_DIR" ]; then
  find "$PACKAGE_DIR" -type f -delete 2>/dev/null || true
  find "$PACKAGE_DIR" -type d -empty -delete 2>/dev/null || true
fi
mkdir -p "$PACKAGE_DIR"

# --- server_light (entry point) ---
echo "[1/7] Copying server_light..."
mkdir -p "$PACKAGE_DIR/server_light/bin"
cp "$SERVER_LIGHT_DIR/bin/server_light.dart" "$PACKAGE_DIR/server_light/bin/"
cp "$SERVER_LIGHT_DIR/pubspec.yaml" "$PACKAGE_DIR/server_light/"

# --- server (tealkit_server) ---
echo "[2/7] Copying server (tealkit_server)..."
mkdir -p "$PACKAGE_DIR/server/lib"
cp -r "$PROJECT_DIR/server/lib/"* "$PACKAGE_DIR/server/lib/"
cp "$PROJECT_DIR/server/pubspec.yaml" "$PACKAGE_DIR/server/"

# --- api (tealkit_api) ---
echo "[3/7] Copying api (tealkit_api)..."
mkdir -p "$PACKAGE_DIR/api/lib"
cp -r "$PROJECT_DIR/api/lib/"* "$PACKAGE_DIR/api/lib/"
cp "$PROJECT_DIR/api/pubspec.yaml" "$PACKAGE_DIR/api/"

# --- third_party/dart_duckdb_light (stub, no Flutter) ---
echo "[4/7] Copying third_party/dart_duckdb_light..."
mkdir -p "$PACKAGE_DIR/third_party/dart_duckdb_light/lib"
cp -r "$PROJECT_DIR/third_party/dart_duckdb_light/lib/"* "$PACKAGE_DIR/third_party/dart_duckdb_light/lib/"
cp "$PROJECT_DIR/third_party/dart_duckdb_light/pubspec.yaml" "$PACKAGE_DIR/third_party/dart_duckdb_light/"

# --- third_party/llamadart_stub (stub, no build hooks) ---
echo "[5/7] Copying third_party/llamadart_stub..."
mkdir -p "$PACKAGE_DIR/third_party/llamadart_stub/lib"
cp -r "$PROJECT_DIR/third_party/llamadart_stub/lib/"* "$PACKAGE_DIR/third_party/llamadart_stub/lib/"
cp "$PROJECT_DIR/third_party/llamadart_stub/pubspec.yaml" "$PACKAGE_DIR/third_party/llamadart_stub/"

# --- Build & run script ---
echo "[6/7] Creating build+run script..."
cat > "$PACKAGE_DIR/build_and_run.sh" << 'RUNEOF'
#!/usr/bin/env bash
# TealKit Server Light — build & run for ARM devices
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/server_light"
echo "=== TealKit Server Light ==="
echo "[1/2] Resolving dependencies..."
dart pub get
echo "[2/2] Compiling native executable..."
dart compile exe bin/server_light.dart -o ../tealkit-server-light
echo ""
echo "Build succeeded: ../tealkit-server-light"
echo "Starting server..."
exec ../tealkit-server-light
RUNEOF
chmod +x "$PACKAGE_DIR/build_and_run.sh"

# --- README ---
echo "[7/7] Creating README..."
cat > "$PACKAGE_DIR/README.txt" << 'READEOF'
TealKit Server Light — ARM Deployment Package
=============================================

Requirements on the target device:
  - Dart SDK >= 3.8.0 (install: bash server_light/scripts/install_dart_arm.sh)

To build & run:
  1. Extract:  tar xzf tealkit_light_deploy.tar.gz
  2. Start:    bash build_and_run.sh

This will compile a standalone native executable, then run it.
The binary is at: tealkit-server-light

For direct run without compilation:
  cd server_light && dart run bin/server_light.dart

For persistent deployment, use a systemd service or supervisor.
READEOF

# --- Package ---
cd "$OUTPUT_DIR"
tar czf "$PACKAGE_TARBALL" "tealkit_light_deploy"
rm -rf "$PACKAGE_DIR"

echo ""
echo "========================================="
echo " Package created: $PACKAGE_TARBALL"
echo ""
SIZE=$(du -h "$PACKAGE_TARBALL" | cut -f1)
echo " Size: $SIZE"
echo ""
echo " To deploy to your ARM device:"
echo "   scp $PACKAGE_TARBALL user@arm-device:/opt/tealkit/"
echo ""
echo " On the ARM device:"
echo "   cd /opt/tealkit"
echo "   tar xzf tealkit_light_deploy.tar.gz"
echo "   bash build_and_run.sh"
echo "========================================="
