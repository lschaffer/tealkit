#!/usr/bin/env bash
# bootstrap_venv_mac.sh — Create arm64 Python 3.11 venv for MLX training on Apple Silicon.
# Usage: bash scripts_training/bootstrap_venv_mac.sh [venv_path]

set -euo pipefail

VENV_PATH="${1:-scripts_training/.venv}"
UV_BIN="${HOME}/.local/bin/uv"
PYTHON_SPEC="cpython-3.11-macos-aarch64-none"

# ── Locate uv ────────────────────────────────────────────────────────────────
if ! command -v "$UV_BIN" >/dev/null 2>&1; then
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
  else
    echo "[venv] uv not found. Installing..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
    UV_BIN="${HOME}/.local/bin/uv"
  fi
fi

echo "[venv] uv: $UV_BIN"
echo "[venv] uv arch: $(file "$UV_BIN" | grep -o 'arm64\|x86_64' | head -1)"

# ── Install arm64 Python 3.11 explicitly ─────────────────────────────────────
echo "[venv] Installing ${PYTHON_SPEC}..."
"$UV_BIN" python install "${PYTHON_SPEC}"

# ── Create venv ───────────────────────────────────────────────────────────────
echo "[venv] Creating venv at: ${VENV_PATH}"
rm -rf "${VENV_PATH}"
"$UV_BIN" venv --python "${PYTHON_SPEC}" "${VENV_PATH}"

# ── Verify arm64 ─────────────────────────────────────────────────────────────
ARCH="$("${VENV_PATH}/bin/python" -c "import platform; print(platform.machine())")"
if [ "${ARCH}" != "arm64" ]; then
  echo "[venv] ERROR: venv Python is ${ARCH}, expected arm64. Cannot install mlx-lm."
  exit 1
fi
echo "[venv] Python arch: ${ARCH} ✓"

# ── Install packages ──────────────────────────────────────────────────────────
echo "[venv] Installing pip, mlx-lm, huggingface_hub..."
"$UV_BIN" pip install --python "${VENV_PATH}/bin/python" -U \
  pip setuptools wheel mlx-lm huggingface_hub

echo ""
echo "[venv] Done."
echo "[venv] Activate with:  source ${VENV_PATH}/bin/activate"
echo "[venv] Verify with:    python -c \"import mlx; print('mlx OK')\""
