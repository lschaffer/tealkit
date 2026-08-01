#!/usr/bin/env bash
# Install Dart SDK on ARM Linux (32-bit armhf / 64-bit arm64)
# Usage: bash install_dart_arm.sh [version]
# Example: bash install_dart_arm.sh 3.8.0
set -e

DART_VERSION="${1:-3.8.0}"
ARCH="$(uname -m)"

# Determine the correct Dart SDK archive name
if [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv6l" ]; then
  SDK_ARCH="arm"
elif [ "$ARCH" = "aarch64" ]; then
  SDK_ARCH="arm64"
else
  echo "Unknown architecture: $ARCH"
  echo "Supported: armv7l, armv6l (32-bit ARM), aarch64 (64-bit ARM)"
  exit 1
fi

echo "Installing Dart SDK $DART_VERSION for linux-$SDK_ARCH..."

# Install dependencies
sudo apt update && sudo apt install -y wget unzip

# Download Dart SDK
URL="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-${SDK_ARCH}-release.zip"
echo "Downloading: $URL"
wget "$URL"

# Extract to /usr/local
sudo unzip -o "dartsdk-linux-${SDK_ARCH}-release.zip" -d /usr/local/

# Add to PATH
if ! grep -q '/usr/local/dart-sdk/bin' ~/.bashrc 2>/dev/null; then
  echo 'export PATH="/usr/local/dart-sdk/bin:$PATH"' >> ~/.bashrc
fi
export PATH="/usr/local/dart-sdk/bin:$PATH"

# Cleanup
rm -f "dartsdk-linux-${SDK_ARCH}-release.zip"

# Verify
echo ""
dart --version
echo ""
echo "Dart SDK installed successfully."
echo "Run 'source ~/.bashrc' or open a new terminal to use dart."


# Create data directory
mkdir -p /root/.tealkit-server/db

# Install SQLite3 shared library (required by dart:sqlite3)
apt-get update && apt-get install -y libsqlite3-0

#apt-get update && apt-get install -y libsqlite3-0
apt-get install -y libsqlite3-dev
