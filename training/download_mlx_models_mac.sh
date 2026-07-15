#!/usr/bin/env bash
set -euo pipefail

# Download MLX model repos for local Mac training.
# Usage:
#   bash download_mlx_models_mac.sh [--preset <name>]
#   MODEL_PRESET=phi4 bash download_mlx_models_mac.sh
#
# Supported presets: qwen3_4b | phi4 | qwen2_5_3b
# Default: qwen3_4b  (gemma4_e2b is Colab-only — mlx-lm cannot train VLMs)
#
# Note: some repos require Hugging Face login and license acceptance
# (especially Gemma 4 — accept the license on https://huggingface.co/google/gemma-4-e2b-it).
# Login if needed:  hf auth login

# ── Parse --preset argument ──────────────────────────────────────────────────
MODEL_PRESET="${MODEL_PRESET:-qwen3_4b}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset) MODEL_PRESET="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Resolve model IDs from preset ────────────────────────────────────────────
case "$MODEL_PRESET" in
  gemma4_e2b)
    echo "[ERROR] gemma4_e2b is a VLM — not trainable with mlx-lm. Use Colab instead."
    exit 1
    ;;
  qwen3_4b)
    TRAIN_MODEL="mlx-community/Qwen3-4B-4bit"
    FUSE_MODEL="Qwen/Qwen3-4B"
    ;;
  phi4)
    TRAIN_MODEL="mlx-community/Phi-4-mini-instruct-4bit"
    FUSE_MODEL="microsoft/Phi-4-mini-instruct"
    ;;
  qwen2_5_3b)
    TRAIN_MODEL="mlx-community/Qwen2.5-3B-Instruct-4bit"
    FUSE_MODEL="Qwen/Qwen2.5-3B-Instruct"
    ;;
  *)
    echo "[ERROR] Unknown preset: $MODEL_PRESET. Supported: qwen3_4b, phi4, qwen2_5_3b"
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_HF="$SCRIPT_DIR/.venv/bin/hf"

if [ -x "$VENV_HF" ]; then
  HF_BIN="$VENV_HF"
elif command -v hf >/dev/null 2>&1; then
  HF_BIN="hf"
else
  echo "[ERROR] hf CLI not found. Activate scripts_training/.venv or install huggingface_hub."
  exit 1
fi

echo "[INFO] Using hf CLI: $HF_BIN"
echo "[INFO] Preset       : $MODEL_PRESET"
echo "[INFO] Train model  : $TRAIN_MODEL"
echo "[INFO] Fuse model   : $FUSE_MODEL  (download with --also-fuse)"
echo "[INFO] Downloading MLX train model..."

"$HF_BIN" download "$TRAIN_MODEL"

# Uncomment to also download the full-precision base (needed for fuse/GGUF export, ~5–15 GB):
# "$HF_BIN" download "$FUSE_MODEL"

echo "[OK] Download step completed"
