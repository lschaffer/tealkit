#!/usr/bin/env bash
set -euo pipefail

# Upload a GGUF model to tealkit.dev into:
# /apps/containers/vol/nginx/www/root/download/models/<model-name>/
#
# Usage:
#   bash scripts_training/upload_gguf_to_tealkit.sh
#   bash scripts_training/upload_gguf_to_tealkit.sh /path/to/model.gguf
#   TEALKIT_SSH_PASSWORD='your-password' bash scripts_training/upload_gguf_to_tealkit.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_GGUF_DIR="$SCRIPT_DIR/../weathersensorsmcp/mcp_fused_model"
REMOTE_HOST="${REMOTE_HOST:-tealkit.dev}"
REMOTE_USER="${REMOTE_USER:-tealkit}"
REMOTE_BASE="${REMOTE_BASE:-/apps/containers/vol/nginx/www/root/download/models}"

INPUT_GGUF="${1:-}"

if [ -n "$INPUT_GGUF" ]; then
  GGUF_FILE="$INPUT_GGUF"
else
  GGUF_FILE="$(ls -1t "$DEFAULT_GGUF_DIR"/*.gguf 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$GGUF_FILE" ]; then
  echo "[ERROR] No GGUF file found."
  echo "[ERROR] Provide a path or place a .gguf file in $DEFAULT_GGUF_DIR"
  exit 1
fi

if [ ! -f "$GGUF_FILE" ]; then
  echo "[ERROR] GGUF file does not exist: $GGUF_FILE"
  exit 1
fi

MODEL_NAME="$(basename "$GGUF_FILE" .gguf)"
REMOTE_DIR="$REMOTE_BASE/$MODEL_NAME"

echo "[INFO] Local GGUF: $GGUF_FILE"
echo "[INFO] Remote host: $REMOTE_USER@$REMOTE_HOST"
echo "[INFO] Remote dir:  $REMOTE_DIR"

SSH_OPTS=("-o" "StrictHostKeyChecking=accept-new")

if command -v sshpass >/dev/null 2>&1 && [ -n "${TEALKIT_SSH_PASSWORD:-}" ]; then
  echo "[INFO] Using sshpass with TEALKIT_SSH_PASSWORD"
  SSHPASS=(sshpass -p "$TEALKIT_SSH_PASSWORD")
  "${SSHPASS[@]}" ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'"
  "${SSHPASS[@]}" scp "${SSH_OPTS[@]}" "$GGUF_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
else
  if [ -z "${TEALKIT_SSH_PASSWORD:-}" ]; then
    echo "[INFO] TEALKIT_SSH_PASSWORD is not set; SSH will prompt for password."
  else
    echo "[INFO] sshpass is not installed; SSH will prompt for password."
  fi
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'"
  scp "${SSH_OPTS[@]}" "$GGUF_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
fi

echo "[INFO] Remote directory listing:"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "ls -lah '$REMOTE_DIR'"

echo "[OK] Upload complete"
