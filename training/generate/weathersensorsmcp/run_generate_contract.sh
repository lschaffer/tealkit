#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

EXAMPLE_GEN_PROVIDER="${EXAMPLE_GEN_PROVIDER:-deepseek}"
EXAMPLE_GEN_MODEL="${EXAMPLE_GEN_MODEL:-${GEMINI_MODEL:-deepseek-v4-pro}}"

case "$EXAMPLE_GEN_PROVIDER" in
  deepseek)
    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
      echo "Error: DEEPSEEK_API_KEY is not set. Export it before running this script."
      exit 1
    fi
    ;;
  gemini)
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
      echo "Error: GEMINI_API_KEY is not set. Export it before running this script."
      exit 1
    fi
    ;;
  openai_compatible)
    if [[ -z "${EXAMPLE_GEN_API_KEY:-}" || -z "${EXAMPLE_GEN_BASE_URL:-}" ]]; then
      echo "Error: EXAMPLE_GEN_API_KEY and EXAMPLE_GEN_BASE_URL must be set for EXAMPLE_GEN_PROVIDER=openai_compatible."
      exit 1
    fi
    ;;
  *)
    echo "Error: unsupported EXAMPLE_GEN_PROVIDER '$EXAMPLE_GEN_PROVIDER'. Use deepseek, gemini, or openai_compatible."
    exit 1
    ;;
esac

PYTHON_BIN="scripts_training/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Error: $PYTHON_BIN not found. Create venv first (see scripts_training/bootstrap_venv_mac.sh)."
  exit 1
fi

SERVER_SCOPE="${SERVER_SCOPE:-weathersensorsmcp}"
CONTRACT_TYPE="${CONTRACT_TYPE:-text_tool_call}"
CONTRACT_CONFIG="${CONTRACT_CONFIG:-scripts_training/servers/$SERVER_SCOPE/configs/$CONTRACT_TYPE/config.json}"
OUTPUT_DIR_OVERRIDE="${OUTPUT_DIR_OVERRIDE:-}"
INCREMENTAL="${INCREMENTAL:-0}"
COUNT="${COUNT:-360}"
MIN_VALID="${MIN_VALID:-300}"
TOTAL="${TOTAL:-600}"
TOOLS_PER_CHUNK="${TOOLS_PER_CHUNK:-6}"
EXAMPLES_PER_CHUNK="${EXAMPLES_PER_CHUNK:-90}"
ATTEMPTS_PER_CHUNK="${ATTEMPTS_PER_CHUNK:-4}"
GEMINI_MODEL="${GEMINI_MODEL:-$EXAMPLE_GEN_MODEL}"

if [[ ! -f "$CONTRACT_CONFIG" ]]; then
  echo "Error: contract config not found: $CONTRACT_CONFIG"
  exit 1
fi

CONFIG_EXPORTS="$($PYTHON_BIN - "$CONTRACT_CONFIG" <<'PYEOF'
import json
import shlex
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    config = json.load(handle)

mapping = {
    'data_dir': 'OUTPUT_DIR',
    'tools_json': 'TOOLS_JSON',
    'template_md': 'TEMPLATE_MD',
}

for key, shell_name in mapping.items():
    value = config.get(key)
    if isinstance(value, str) and value:
        print(f"{shell_name}={shlex.quote(value)}")
PYEOF
)"

eval "$CONFIG_EXPORTS"

if [[ -z "${OUTPUT_DIR:-}" || -z "${TOOLS_JSON:-}" || -z "${TEMPLATE_MD:-}" ]]; then
  echo "Error: contract config must define data_dir, tools_json, and template_md"
  exit 1
fi

normalize_path() {
  local path_value="$1"
  if [[ "$path_value" = /* ]]; then
    printf '%s\n' "$path_value"
  elif [[ "$path_value" == scripts_training/* ]]; then
    printf '%s\n' "$path_value"
  else
    printf 'scripts_training/%s\n' "$path_value"
  fi
}

TOOLS_JSON="$(normalize_path "$TOOLS_JSON")"
TEMPLATE_MD="$(normalize_path "$TEMPLATE_MD")"
OUTPUT_DIR="$(normalize_path "$OUTPUT_DIR")"

if [[ -n "$OUTPUT_DIR_OVERRIDE" ]]; then
  OUTPUT_DIR="$OUTPUT_DIR_OVERRIDE"
fi

PROMPT_OUT="$OUTPUT_DIR/generated_train_prompt.md"
OUT_JSONL="$OUTPUT_DIR/train.jsonl"
TRAIN_SPLIT="$OUTPUT_DIR/train_split.jsonl"
VALID_SPLIT="$OUTPUT_DIR/valid_split.jsonl"

mkdir -p "$OUTPUT_DIR"

"$PYTHON_BIN" scripts_training/common/py/dataset/train_dataset_cli.py \
  --build-prompt \
  --output-dir "$OUTPUT_DIR" \
  --template "$TEMPLATE_MD" \
  --tools "$TOOLS_JSON" \
  --prompt-out "$PROMPT_OUT"

if [[ "$INCREMENTAL" == "1" ]]; then
  "$PYTHON_BIN" scripts_training/generate/py/generate_train_jsonl_gemini_incremental.py \
    --prompt "$PROMPT_OUT" \
    --out "$OUT_JSONL" \
    --tools "$TOOLS_JSON" \
    --contract-type "$CONTRACT_TYPE" \
    --model "$GEMINI_MODEL" \
    --total "$TOTAL" \
    --tools-per-chunk "$TOOLS_PER_CHUNK" \
    --examples-per-chunk "$EXAMPLES_PER_CHUNK" \
    --attempts-per-chunk "$ATTEMPTS_PER_CHUNK"
else
  "$PYTHON_BIN" scripts_training/generate/py/generate_train_jsonl_gemini.py \
    --prompt "$PROMPT_OUT" \
    --out "$OUT_JSONL" \
    --tools "$TOOLS_JSON" \
    --contract-type "$CONTRACT_TYPE" \
    --model "$GEMINI_MODEL" \
    --count "$COUNT" \
    --min-valid "$MIN_VALID"
fi

"$PYTHON_BIN" scripts_training/common/py/dataset/validate_jsonl.py \
  --jsonl "$OUT_JSONL" \
  --tools "$TOOLS_JSON" \
  --contract-type "$CONTRACT_TYPE"

"$PYTHON_BIN" scripts_training/common/py/dataset/train_dataset_cli.py \
  --jsonl "$OUT_JSONL" \
  --train-out "$TRAIN_SPLIT" \
  --valid-out "$VALID_SPLIT" \
  --contract-type "$CONTRACT_TYPE" \
  --split

valid_lines="$($PYTHON_BIN scripts_training/common/py/dataset/validate_jsonl.py --jsonl "$OUT_JSONL" --tools "$TOOLS_JSON" --contract-type "$CONTRACT_TYPE" 2>/dev/null | awk '/Valid lines:/ {print $3; exit}')"
if [[ -n "$valid_lines" ]] && (( valid_lines < MIN_VALID )); then
  echo "Error: generated only $valid_lines valid lines, below MIN_VALID=$MIN_VALID"
  exit 1
fi

echo "Done. Generated training data: $OUT_JSONL"
