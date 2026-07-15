#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════
# Download and register a model from HuggingFace to Ollama
# ══════════════════════════════════════════════════════════
#
# Downloads GGUF and Modelfile from a HuggingFace repository and registers
# the model with Ollama. The Modelfile contains the required TEMPLATE for
# tool support.
#
# Usage:
#   ./download-hf-model.sh <repo> [model-name] [gguf-pattern]
#
# Examples:
#   ./download-hf-model.sh username/qwen2.5-3b-weathersensorsmcp
#   ./download-hf-model.sh username/ministral-3b-weathersensorsmcp ministral-weather
#   ./download-hf-model.sh username/qwen2.5-3b-weathersensorsmcp "" "*f16.gguf"
#

REPO="${1:-}"
MODEL_NAME="${2:-}"
GGUF_PATTERN="${3:-*q5_k_m.gguf}"
GGUF_FILE=""
REMOTE_GGUF_FILE=""
LOCAL_GGUF_FILE=""

if [ -z "$REPO" ]; then
    echo "Usage: $0 <repo> [model-name] [gguf-pattern]"
    echo ""
    echo "Examples:"
    echo "  $0 username/qwen2.5-3b-weathersensorsmcp"
    echo "  $0 username/ministral-3b-weathersensorsmcp ministral-weather"
    echo "  $0 username/qwen2.5-3b-weathersensorsmcp \"\" \"*f16.gguf\""
    exit 1
fi

# Derive model name from repo if not specified
if [ -z "$MODEL_NAME" ]; then
    MODEL_NAME=$(basename "$REPO")
fi

OUTPUT_DIR="./hf_models/$(basename "$REPO")"
BASE_URL="https://huggingface.co/$REPO/resolve/main"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Download & Register HuggingFace Model to Ollama"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Repository    : $REPO"
echo "Model name    : $MODEL_NAME"
echo "Output dir    : $OUTPUT_DIR"
echo "GGUF pattern  : $GGUF_PATTERN"
echo ""

# ══════════════════════════════════════════════════════════
# STEP 1: Fetch available files from HF repo
# ══════════════════════════════════════════════════════════

echo "[1/5] Fetching file list from HuggingFace..."

API_URL="https://huggingface.co/api/models/$REPO/tree/main"
MODEL_API_URL="https://huggingface.co/api/models/$REPO"
AUTH_HEADER=()
if [ -n "${HF_TOKEN:-}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${HF_TOKEN}")
fi

fetch_hf_json() {
    local url="$1"
    local body status

    body=$(curl -sSL "${AUTH_HEADER[@]}" -w $'\n%{http_code}' "$url" 2>/dev/null || true)
    status=$(printf '%s\n' "$body" | tail -n 1)
    body=$(printf '%s\n' "$body" | sed '$d')

    printf '%s\n%s' "$status" "$body"
}

read_hf_response() {
    local url="$1"
    local result

    result=$(fetch_hf_json "$url")
    HF_HTTP_STATUS=$(printf '%s\n' "$result" | head -n 1)
    FILES_JSON=$(printf '%s\n' "$result" | sed '1d')
}

suggest_repo_slug() {
    case "$REPO" in
        lschaffer/qwen25-3b-weathersensorsmcp)
            echo "  The current repo slug is: lschaffer/qwen2.5-3b-weathersensorsmcp"
            ;;
        lschaffer/qwen25-3b-weathersensorsmcp)
            echo "  The current repo slug is: lschaffer/qwen2.5-3b-weathersensorsmcp"
            ;;
    esac
}

HF_HTTP_STATUS=""
read_hf_response "$API_URL"

# Parse JSON to extract file paths. HF may return either:
# - tree endpoint array items with .path/.type
# - model endpoint object with .siblings[].rfilename
if command -v jq >/dev/null 2>&1; then
    if [ -n "$FILES_JSON" ] && echo "$FILES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
        FILES=$(echo "$FILES_JSON" | jq -r '.[] | select((.type // "") == "file" or (.path? != null)) | .path')
    else
        read_hf_response "$MODEL_API_URL"

        if [ -n "$FILES_JSON" ] && echo "$FILES_JSON" | jq -e 'type == "object" and (.siblings? | type == "array")' >/dev/null 2>&1; then
            FILES=$(echo "$FILES_JSON" | jq -r '.siblings[] | .rfilename')
        else
            HF_ERROR=$(echo "$FILES_JSON" | jq -r '.error // .message // empty' 2>/dev/null || true)
            echo "✗ Failed to fetch a file list from HuggingFace for $REPO"
            if [ -n "$HF_HTTP_STATUS" ]; then
                echo "  HTTP status: $HF_HTTP_STATUS"
            fi
            if [ -n "$HF_ERROR" ]; then
                echo "  HuggingFace response: $HF_ERROR"
            fi
            if [ "$HF_HTTP_STATUS" = "401" ] || [ "$HF_HTTP_STATUS" = "403" ]; then
                echo "  If the repo is private or gated, export HF_TOKEN before running this script."
            fi
            if [ "$HF_HTTP_STATUS" = "404" ]; then
                suggest_repo_slug
            fi
            exit 1
        fi
    fi
else
    if [ -z "$FILES_JSON" ] || ! echo "$FILES_JSON" | grep -q '"path"'; then
        read_hf_response "$MODEL_API_URL"
    fi

    # Fallback: extract paths with grep (less robust but works without jq)
    FILES=$(
        echo "$FILES_JSON" | grep -o '"path":"[^"]*"\|"rfilename":"[^"]*"' \
        | sed 's/"path":"//g' \
        | sed 's/"rfilename":"//g' \
        | sed 's/"//g'
    )

    if [ -z "$FILES" ]; then
        echo "✗ Failed to parse a file list from HuggingFace for $REPO"
        if [ -n "$HF_HTTP_STATUS" ]; then
            echo "  HTTP status: $HF_HTTP_STATUS"
        fi
        if [ "$HF_HTTP_STATUS" = "404" ]; then
            suggest_repo_slug
        fi
        exit 1
    fi
fi

# Find GGUF file matching pattern
GGUF_FILE=$(echo "$FILES" | grep -E "${GGUF_PATTERN//\*/.*}" | head -n 1 || true)

if [ -z "$GGUF_FILE" ]; then
    # Recovery path for older uploads or notebook export bugs:
    # - default Q5 request but repo only has a Q4 file
    # - malformed filename ending in .ggu instead of .gguf
    RECOVERY_GGUF=$(echo "$FILES" | grep -Ei 'q4_k_m\.(gguf|ggu)$|\.gguf$|\.ggu$' | head -n 1 || true)
    if [ -n "$RECOVERY_GGUF" ] && [ "$GGUF_PATTERN" = "*q5_k_m.gguf" ]; then
        GGUF_FILE="$RECOVERY_GGUF"
        echo "⚠ No file matched the default pattern '$GGUF_PATTERN'."
        echo "  Falling back to: $GGUF_FILE"
        if echo "$GGUF_FILE" | grep -qi '\.ggu$'; then
            echo "  The repository filename looks malformed (.ggu). The script will download it and normalize it locally to .gguf."
        fi
    fi
fi

if [ -z "$GGUF_FILE" ]; then
    echo "✗ No GGUF file matching pattern '$GGUF_PATTERN' found in repository."
    echo "  Available files:"
    echo "$FILES" | sed 's/^/    /'
    exit 1
fi

REMOTE_GGUF_FILE="$GGUF_FILE"
LOCAL_GGUF_FILE="$GGUF_FILE"
if echo "$LOCAL_GGUF_FILE" | grep -qi '\.ggu$'; then
    LOCAL_GGUF_FILE="${LOCAL_GGUF_FILE}f"
fi

# Check for Modelfile
HAS_MODELFILE=$(echo "$FILES" | grep -x "Modelfile" || true)
if [ -z "$HAS_MODELFILE" ]; then
    echo "✗ Modelfile not found in repository."
    echo "  The Modelfile is required for tool support."
    exit 1
fi

echo "✓ Found GGUF: $GGUF_FILE"
echo "✓ Found Modelfile"

# ══════════════════════════════════════════════════════════
# STEP 2: Create output directory
# ══════════════════════════════════════════════════════════

echo ""
echo "[2/5] Creating output directory..."

mkdir -p "$OUTPUT_DIR"
echo "✓ Directory: $OUTPUT_DIR"

# ══════════════════════════════════════════════════════════
# STEP 3: Download GGUF
# ══════════════════════════════════════════════════════════

echo ""
echo "[3/5] Downloading GGUF (this may take several minutes)..."

GGUF_URL="$BASE_URL/$REMOTE_GGUF_FILE"
GGUF_PATH="$OUTPUT_DIR/$LOCAL_GGUF_FILE"

if [ -f "$GGUF_PATH" ]; then
    echo "✓ GGUF already exists, skipping download: $GGUF_PATH"
else
    curl -L -o "$GGUF_PATH" "$GGUF_URL" --progress-bar || {
        echo "✗ Failed to download GGUF"
        exit 1
    }
    echo "✓ Downloaded: $GGUF_PATH"
fi

# ══════════════════════════════════════════════════════════
# STEP 4: Download Modelfile
# ══════════════════════════════════════════════════════════

echo ""
echo "[4/5] Downloading Modelfile..."

MODELFILE_URL="$BASE_URL/Modelfile"
MODELFILE_PATH="$OUTPUT_DIR/Modelfile"

curl -L -o "$MODELFILE_PATH" "$MODELFILE_URL" || {
    echo "✗ Failed to download Modelfile"
    exit 1
}

if [ "$REMOTE_GGUF_FILE" != "$LOCAL_GGUF_FILE" ]; then
    perl -0pi -e 's/^FROM\s+\Q'"$REMOTE_GGUF_FILE"'\E$/FROM '"$LOCAL_GGUF_FILE"'/m' "$MODELFILE_PATH"
    echo "✓ Normalized local Modelfile FROM target to: $LOCAL_GGUF_FILE"
fi

# App/runtime clients already inject their own current system/tool prompt.
# Remove baked-in SYSTEM blocks so native Ollama tool calling is not forced
# back into the text-only training format during app use.
if grep -q '^SYSTEM ' "$MODELFILE_PATH"; then
    perl -0pi -e 's/^SYSTEM\s+""".*?(?=^(?:FROM|LICENSE|TEMPLATE|SYSTEM|ADAPTER|RENDERER|PARSER|PARAMETER|MESSAGE|REQUIRES)\b)//msg; s/^SYSTEM\s+".*?(?=^(?:FROM|LICENSE|TEMPLATE|SYSTEM|ADAPTER|RENDERER|PARSER|PARAMETER|MESSAGE|REQUIRES)\b)//msg' "$MODELFILE_PATH"
    echo "✓ Removed embedded SYSTEM block from local Modelfile for app-safe Ollama registration"
fi
echo "✓ Downloaded: $MODELFILE_PATH"

# ══════════════════════════════════════════════════════════
# STEP 5: Register with Ollama
# ══════════════════════════════════════════════════════════

echo ""
echo "[5/5] Registering model with Ollama..."

# Check if Ollama is available
if ! command -v ollama >/dev/null 2>&1; then
    echo "✗ Ollama is not available. Please install Ollama first:"
    echo "  https://ollama.com/download"
    exit 1
fi

# Check if model already exists
if ollama list 2>/dev/null | grep -q "^${MODEL_NAME}[[:space:]]"; then
    echo "⚠ Model '$MODEL_NAME' already exists in Ollama."
    read -p "  Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "✓ Keeping existing model."
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  To use the model:"
        echo "    ollama run $MODEL_NAME"
        echo "═══════════════════════════════════════════════════════════"
        exit 0
    fi
    ollama rm "$MODEL_NAME" >/dev/null 2>&1 || true
fi

# Register the model
(
    cd "$OUTPUT_DIR"
    echo "  Running: ollama create $MODEL_NAME -f Modelfile"
    ollama create "$MODEL_NAME" -f Modelfile || {
        echo "✗ Failed to register model"
        exit 1
    }
)
echo "✓ Model registered: $MODEL_NAME"

# ══════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ✓ SUCCESS"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Model downloaded to: $OUTPUT_DIR"
echo "Model registered as: $MODEL_NAME"
echo ""
echo "To use the model:"
echo "  ollama run $MODEL_NAME"
echo ""
echo "To test tool support:"
echo "  ollama run $MODEL_NAME 'What tools do you have?'"
echo ""
