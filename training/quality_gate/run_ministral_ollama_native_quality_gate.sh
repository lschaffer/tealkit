#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_ministral_ollama_native_quality_gate.sh
#
# Quality gate for Ministral 3B trained via Colab (Unsloth, Mistral [INST] template, native contract).
# Use this AFTER Colab Cell 10 has pushed the new model to HF.
#
# Usage:
#   # Download freshly trained model from HF and test:
#   ./run_ministral_ollama_native_quality_gate.sh --from-hf
#
#   # Provide a local GGUF (e.g. downloaded from Google Drive):
#   ./run_ministral_ollama_native_quality_gate.sh --gguf /path/to/ministral-3b-weathersensorsmcp-ollama-unsloth-Q5_K_M.gguf
#
# Options:
#   --gguf PATH          Use a local GGUF file (skips HF download)
#   --from-hf            Download from HF (re-downloads if already cached)
#   --hf-repo REPO       HF repo to pull from (default: lschaffer/ministral-3b-weathersensorsmcp-ollama)
#   --filename NAME      GGUF filename in the repo (default: ministral-3b-weathersensorsmcp-ollama-unsloth-Q5_K_M.gguf)
#   --model-name NAME    Ollama model name to register (default: ministral-3b-weathersensorsmcp-ollama)
#   --num-ctx N          Context window for Ollama (default: 16384 — note: depends on hardware capabilities)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_PROMPT_FILE="$SCRIPT_DIR/../servers/weathersensorsmcp/prompts/ollama_native_system_prompt.md"
PYTHON="${PYTHON:-python3}"

# Defaults
HF_REPO="lschaffer/ministral-3b-weathersensorsmcp-ollama"
GGUF_FILENAME="ministral-3b-weathersensorsmcp-ollama-unsloth-Q5_K_M.gguf"
OLLAMA_MODEL_NAME="ministral-3b-weathersensorsmcp-ollama"
LOCAL_GGUF_PATH=""
FROM_HF=0
NUM_CTX=16384
WORK_DIR="$SCRIPT_DIR/../weathersensorsmcp/ministral_3b_gate_native_tmp"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gguf)       LOCAL_GGUF_PATH="$2"; shift 2 ;;
        --from-hf)    FROM_HF=1; shift ;;
        --hf-repo)    HF_REPO="$2"; shift 2 ;;
        --filename)   GGUF_FILENAME="$2"; shift 2 ;;
        --model-name) OLLAMA_MODEL_NAME="$2"; shift 2 ;;
        --num-ctx)    NUM_CTX="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$LOCAL_GGUF_PATH" ] && [ "$FROM_HF" -eq 0 ]; then
    echo "[ERROR] Provide either --gguf /path/to/model.gguf or --from-hf"
    echo "        Run with --from-hf after Colab Cell 10 has finished uploading."
    exit 1
fi

mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# Step 1: Resolve GGUF path
# ---------------------------------------------------------------------------
if [ -n "$LOCAL_GGUF_PATH" ]; then
    if [ ! -f "$LOCAL_GGUF_PATH" ]; then
        echo "[ERROR] GGUF file not found: $LOCAL_GGUF_PATH"
        exit 1
    fi
    GGUF_ABS="$(cd "$(dirname "$LOCAL_GGUF_PATH")" && pwd)/$(basename "$LOCAL_GGUF_PATH")"
    GGUF_FILENAME="$(basename "$GGUF_ABS")"
    GGUF_DIR="$(dirname "$GGUF_ABS")"
    echo "[INFO] Using local GGUF: $GGUF_ABS"
else
    GGUF_DIR="$WORK_DIR"
    GGUF_ABS="$GGUF_DIR/$GGUF_FILENAME"
    HF_URL="https://huggingface.co/${HF_REPO}/resolve/main/${GGUF_FILENAME}"
    echo "[STEP] Downloading $GGUF_FILENAME from $HF_REPO ..."
    # Remove stale copy so we always get the latest version after retraining
    [ -f "$GGUF_ABS" ] && rm "$GGUF_ABS" && echo "[INFO] Removed stale local copy, re-downloading..."
    curl -L --progress-bar -o "$GGUF_ABS" "$HF_URL"
    echo "[INFO] Downloaded to: $GGUF_ABS"
fi

# ---------------------------------------------------------------------------
# Step 2: Read system prompt
# ---------------------------------------------------------------------------
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "[ERROR] System prompt not found: $SYSTEM_PROMPT_FILE"
    exit 1
fi
SYSTEM_PROMPT_CONTENT="$(cat "$SYSTEM_PROMPT_FILE")"

# ---------------------------------------------------------------------------
# Step 3: Write Modelfile with Mistral [INST] template
#
# Ministral 3B uses the Mistral v3 tekken tokenizer. Chat format is [INST]...[/INST]
# with </s> as the EOS/stop token. No thinking mode; no <|im_end|> tokens.
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/Modelfile" <<MODELEOF
FROM $GGUF_ABS
TEMPLATE """{{ if .System }}[INST] {{ .System }}

{{ .Prompt }} [/INST]{{ else }}[INST] {{ .Prompt }} [/INST]{{ end }}"""
SYSTEM """$SYSTEM_PROMPT_CONTENT"""
PARAMETER stop "</s>"
PARAMETER num_ctx $NUM_CTX
PARAMETER num_thread 4
MODELEOF

echo "[INFO] Modelfile written to: $WORK_DIR/Modelfile"

# ---------------------------------------------------------------------------
# Step 4: Register with Ollama
# ---------------------------------------------------------------------------
echo "[STEP] Registering $OLLAMA_MODEL_NAME with Ollama ..."
ollama rm "$OLLAMA_MODEL_NAME" 2>/dev/null || true
ollama create "$OLLAMA_MODEL_NAME" -f "$WORK_DIR/Modelfile"
echo "[INFO] Registered: $OLLAMA_MODEL_NAME"

# ---------------------------------------------------------------------------
# Step 5: Run quality gate
# ---------------------------------------------------------------------------
echo ""
echo "[STEP] Running weathersensorsmcp quality gate ..."
"$PYTHON" "$SCRIPT_DIR/py/quality_gate.py" \
    --model "$OLLAMA_MODEL_NAME" \
    --profile weathersensorsmcp_ollama_native \
    --profile-file "$SCRIPT_DIR/../contracts/ollama_native/quality_gate_profile.json" \
    --system-prompt-file "$SYSTEM_PROMPT_FILE" \
    --num-predict 128 \
    --num-ctx "$NUM_CTX" \
    --retries 2 \
    --force-generate

echo ""
echo "[DONE]"
