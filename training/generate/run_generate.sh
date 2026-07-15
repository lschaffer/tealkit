#!/usr/bin/env bash
set -euo pipefail

# Generic MCP training dataset generator.
#
# Usage:
#   bash scripts_training/run_generate_train_jsonl.sh <tools-json>
#
# Arguments:
#   <tools-json>   Path to the MCP tools schema JSON or JSONL file
#                  Example: scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
#
# Optional env vars:
#   COUNT          Number of examples to request (default: 360)
#   MIN_VALID      Minimum valid lines required (default: 300)
#   TEMPLATE_MD    Prompt template file (default: scripts_training/train.md)
#   OUTPUT_DIR     Base output folder (default: sibling mcp_out if tools dir is mcp_data, else tools dir)
#
# Examples:
#   bash scripts_training/run_generate_train_jsonl.sh scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
#   COUNT=500 MIN_VALID=400 bash scripts_training/run_generate_train_jsonl.sh scripts_training/tealkit/mcp_data/tealkit_tools.json

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <tools-json>"
  echo "Example: $(basename "$0") scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl"
  exit 1
fi

EXAMPLE_GEN_PROVIDER="${EXAMPLE_GEN_PROVIDER:-deepseek}"
EXAMPLE_GEN_MODEL="${EXAMPLE_GEN_MODEL:-${GEMINI_MODEL:-deepseek-v4-pro}}"

case "$EXAMPLE_GEN_PROVIDER" in
  deepseek)
    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
      echo "Error: DEEPSEEK_API_KEY is not set. Export it before running this script."
      echo "Example: export DEEPSEEK_API_KEY='your_key_here'"
      exit 1
    fi
    ;;
  gemini)
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
      echo "Error: GEMINI_API_KEY is not set. Export it before running this script."
      echo "Example: export GEMINI_API_KEY='your_key_here'"
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

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

TOOLS_JSON="$1"

if [[ ! -f "$TOOLS_JSON" ]]; then
  echo "Error: Tools JSON not found: $TOOLS_JSON"
  exit 1
fi

PYTHON_BIN="scripts_training/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Error: $PYTHON_BIN not found. Create venv first (see scripts_training/bootstrap_venv_mac.sh)."
  exit 1
fi

# Derive base name from the tools filename: e.g. weather_sensors_tools.jsonl -> weather_sensors
TOOLS_FILENAME="$(basename "$TOOLS_JSON")"
TOOLS_BASENAME="${TOOLS_FILENAME%.jsonl}"
TOOLS_BASENAME="${TOOLS_BASENAME%.json}"
BASE_NAME="${TOOLS_BASENAME%_tools}"

TEMPLATE_MD="${TEMPLATE_MD:-scripts_training/train.md}"
TOOLS_DIR="$(dirname "$TOOLS_JSON")"
DEFAULT_OUTPUT_DIR="$TOOLS_DIR"
if [[ "$TOOLS_DIR" == */mcp_data ]]; then
  DEFAULT_OUTPUT_DIR="${TOOLS_DIR%/mcp_data}/mcp_out"
fi
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
COUNT="${COUNT:-360}"
MIN_VALID="${MIN_VALID:-300}"

PROMPT_OUT="$OUTPUT_DIR/$BASE_NAME/generated_train_prompt.md"
OUT_JSONL="$OUTPUT_DIR/$BASE_NAME/train.jsonl"

echo "Tools JSON  : $TOOLS_JSON"
echo "Base name   : $BASE_NAME"
echo "Output dir  : $OUTPUT_DIR/$BASE_NAME"
echo "Count       : $COUNT  (min-valid: $MIN_VALID)"

mkdir -p "$OUTPUT_DIR/$BASE_NAME"

# Step 1: Build prompt
"$PYTHON_BIN" scripts_training/common/py/dataset/train_dataset_cli.py \
  --build-prompt \
  --base-name "$BASE_NAME" \
  --output-dir "$OUTPUT_DIR" \
  --template "$TEMPLATE_MD" \
  --tools "$TOOLS_JSON" \
  --prompt-out "$PROMPT_OUT"

# Step 2: Generate JSONL
"$PYTHON_BIN" scripts_training/generate/py/generate_train_jsonl_gemini.py \
  --prompt "$PROMPT_OUT" \
  --out "$OUT_JSONL" \
  --tools "$TOOLS_JSON" \
  --count "$COUNT" \
  --min-valid "$MIN_VALID"

# Step 3: Validate
"$PYTHON_BIN" scripts_training/common/py/dataset/validate_jsonl.py \
  --jsonl "$OUT_JSONL" \
  --tools "$TOOLS_JSON"

# Step 4: Split into train/valid
"$PYTHON_BIN" scripts_training/common/py/dataset/train_dataset_cli.py \
  --base-name "$BASE_NAME" \
  --output-dir "$OUTPUT_DIR" \
  --split

echo ""
echo "Done. Files in $OUTPUT_DIR/$BASE_NAME:"
echo "  train.jsonl        <- full dataset"
echo "  train_split.jsonl  <- for Colab TRAIN_FILE"
echo "  valid_split.jsonl  <- for Colab VALID_FILE"
