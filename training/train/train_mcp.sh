#!/bin/bash
set -e   # exit immediately on any error

# --- CONFIGURATION ---
# Base model: must be an MLX-format HuggingFace repo (safetensors + config.json).
# GGUF repos (e.g. unsloth/Qwen3.5-2B-GGUF) will NOT work - mlx_lm cannot load them.
# Recommended training models (fast):
#   mlx-community/Qwen2.5-1.5B-Instruct-4bit
#   mlx-community/Qwen2.5-3B-Instruct-4bit
#
# Important: GGUF conversion is more reliable when fusing adapters into a
# full-precision HF checkpoint. So we keep separate train/fuse base models.
#
# Ministral presets (requested for Mac MLX):
#   ministral3_3b
#   ministral3_8b
#   ministral3_14b
# Qwen presets:
#   qwen3_4b  (recommended for Mac — best instruct quality <=4B, text-only)
#   qwen2_5_1_5b
#   qwen2_5_3b
# Colab-only presets (VLM, not supported by mlx-lm):
#   gemma4_e2b  → use tealkit_training.ipynb on Colab instead
#
# Also configurable via CLI: --preset <name>
MODEL_PRESET="${MODEL_PRESET:-qwen3_4b}"
MODEL_PRESET_EXPLICIT=0
TRAIN_BASE_MODEL=""
FUSE_BASE_MODEL=""
SERVER_SCOPE="${SERVER_SCOPE:-${MCP_SERVER:-weathersensorsmcp}}"
MCP_SERVER="$SERVER_SCOPE"
CONTRACT_TYPE="${CONTRACT_TYPE:-text_tool_call}"
CONTRACT_CONFIG_FILE="${CONTRACT_CONFIG_FILE:-}"
ADAPTER_PATH="./mcp_adapters"
FUSED_PATH="./mcp_fused_model"
DATA_DIR="${DATA_DIR:-}"
DATASET_BASE_NAME="${DATASET_BASE_NAME:-weather_sensors}"
MODEL_NAME=""   # set automatically by apply_model_preset
CONTRACT_MODEL_NAME_SUFFIX="${CONTRACT_MODEL_NAME_SUFFIX:-}"
GGUF_EXTRA_ARGS=""  # extra flags for convert_hf_to_gguf.py (e.g. --vocab-type bpe)
GGUF_F16=""     # recalculated after preset is applied
GGUF_Q5=""
LLAMA_CPP_DIR="/tmp/llama.cpp"
HF_MODEL_REPO="${HF_MODEL_REPO:-}"
HF_PRIVATE="${HF_PRIVATE:-0}"
HF_ADAPTER_REPO="${HF_ADAPTER_REPO:-}"
HF_ADAPTER_SUBDIR="${HF_ADAPTER_SUBDIR:-adapters}"
TRAIN_SCOPE_WAS_SET="${TRAIN_SCOPE+x}"
MODEL_ARTIFACT_SCOPE_WAS_SET="${MODEL_ARTIFACT_SCOPE+x}"
TRAIN_SCOPE="${TRAIN_SCOPE:-$MCP_SERVER}"
MODEL_ARTIFACT_SCOPE="${MODEL_ARTIFACT_SCOPE:-$TRAIN_SCOPE}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-}"
GITHUB_PROJECT_URL="${GITHUB_PROJECT_URL:-https://github.com/lschaffer/tealkit}"
GITHUB_PAGES_URL="${GITHUB_PAGES_URL:-https://lschaffer.github.io/tealkit}"
GITHUB_TRAINING_GUIDE_URL="${GITHUB_TRAINING_GUIDE_URL:-${GITHUB_PROJECT_URL}/blob/master_v2/traning/README.md}"
TRAIN_ITERS_WAS_SET="${TRAIN_ITERS+x}"
TRAIN_MAX_SEQ_LENGTH_WAS_SET="${TRAIN_MAX_SEQ_LENGTH+x}"
OLLAMA_NUM_CTX_WAS_SET="${OLLAMA_NUM_CTX+x}"
TRAIN_LR_WAS_SET="${TRAIN_LR+x}"
TRAIN_LORA_RANK_WAS_SET="${TRAIN_LORA_RANK+x}"
TRAIN_NUM_LAYERS_WAS_SET="${TRAIN_NUM_LAYERS+x}"
TRAIN_ITERS="${TRAIN_ITERS:-300}"
TRAIN_BATCH_SIZE="${TRAIN_BATCH_SIZE:-2}"
TRAIN_GRAD_ACCUM_STEPS="${TRAIN_GRAD_ACCUM_STEPS:-2}"
TRAIN_MAX_SEQ_LENGTH="${TRAIN_MAX_SEQ_LENGTH:-1024}"
TRAIN_ENABLE_GRAD_CHECKPOINT="${TRAIN_ENABLE_GRAD_CHECKPOINT:-1}"
TRAIN_MASK_PROMPT="${TRAIN_MASK_PROMPT:-1}"
TRAIN_LR="${TRAIN_LR:-5e-6}"
TRAIN_LORA_RANK="${TRAIN_LORA_RANK:-8}"
TRAIN_NUM_LAYERS="${TRAIN_NUM_LAYERS:-16}"
OLLAMA_STOP_PARAMS=""
# ChatML TEMPLATE for Ollama Modelfile — set per preset for models that need it.
# Without this, Ollama falls back to TEMPLATE {{ .Prompt }} (raw completion) and the
# SYSTEM block is never injected, causing the model to ignore the format instructions.
OLLAMA_TEMPLATE=""
OLLAMA_EMBED_SYSTEM_PROMPT="${OLLAMA_EMBED_SYSTEM_PROMPT:-0}"
RESUME_IF_ADAPTER_EXISTS="${RESUME_IF_ADAPTER_EXISTS:-0}"
ADAPTER_ITER_OVERRIDE="${ADAPTER_ITER_OVERRIDE:-}"
ADAPTER_FILE_OVERRIDE="${ADAPTER_FILE_OVERRIDE:-}"
TRAIN_FILE="${TRAIN_FILE:-}"
VALID_FILE="${VALID_FILE:-}"
MIN_TRAIN_LINES="${MIN_TRAIN_LINES:-200}"
ALLOW_TRAIN_VALID_OVERLAP="${ALLOW_TRAIN_VALID_OVERLAP:-0}"
ALLOW_SEQUENCE_TRUNCATION="${ALLOW_SEQUENCE_TRUNCATION:-0}"
FORCE_OLLAMA_RECREATE="${FORCE_OLLAMA_RECREATE:-1}"
OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-1024}"
OLLAMA_NUM_THREAD="${OLLAMA_NUM_THREAD:-4}"
GENERIC_SYSTEM_PROMPT='You are a specialized MCP Agent with access to tools. When a user asks a question relevant to your tools, respond ONLY with a JSON tool call in this exact format: tool_call: {"name": "<tool_name>", "arguments": {...}}. Do not include any explanatory text. If no tool applies, respond naturally without tool_call prefix.'

# Resolve venv - script lives in scripts_training/, venv is scripts_training/.venv/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_BIN="$SCRIPT_DIR/../.venv/bin"
PYTHON="$VENV_BIN/python"
UV="${HOME}/.local/bin/uv"
PY_HELPERS_DIR="$SCRIPT_DIR/py"

# Normalize training paths to the script directory so the workflow works
# regardless of the caller's current working directory.
ADAPTER_PATH="$SCRIPT_DIR/../$MODEL_ARTIFACT_SCOPE/mcp_adapters"
FUSED_PATH="$SCRIPT_DIR/../$MODEL_ARTIFACT_SCOPE/mcp_fused_model"
if [ -n "$DATA_DIR" ]; then
    case "$DATA_DIR" in
        /*) ;;
        *) DATA_DIR="$SCRIPT_DIR/../$DATA_DIR" ;;
    esac
else
    DATA_DIR="$SCRIPT_DIR/../$TRAIN_SCOPE/mcp_out"
fi

resolve_scripts_training_path() {
    local path_value="$1"
    if [ -z "$path_value" ]; then
        return
    fi
    case "$path_value" in
        /*) echo "$path_value" ;;
        *) echo "$SCRIPT_DIR/../$path_value" ;;
    esac
}

resolve_contract_config_file() {
    if [ -n "$CONTRACT_CONFIG_FILE" ] && [ -f "$CONTRACT_CONFIG_FILE" ]; then
        resolve_scripts_training_path "$CONTRACT_CONFIG_FILE"
        return
    fi

    local candidate="$SCRIPT_DIR/../servers/$SERVER_SCOPE/configs/$CONTRACT_TYPE/config.json"
    if [ -f "$candidate" ]; then
        echo "$candidate"
    fi
}

apply_contract_config() {
    local config_file="$1"
    if [ -z "$config_file" ]; then
        return
    fi

    local assignments
    assignments="$(python3 - "$config_file" <<'PYEOF'
import json
import shlex
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

mapping = {
    "train_scope": "TRAIN_SCOPE",
    "model_artifact_scope": "MODEL_ARTIFACT_SCOPE",
    "data_dir": "DATA_DIR",
    "quality_gate_profile": "QUALITY_GATE_PROFILE",
    "quality_gate_profile_file": "QUALITY_GATE_PROFILE_FILE",
    "system_prompt_file": "SYSTEM_PROMPT_FILE",
    "contract_model_name_suffix": "CONTRACT_MODEL_NAME_SUFFIX",
}

for key, shell_name in mapping.items():
    value = config.get(key)
    if isinstance(value, str) and value:
        print(f"{shell_name}={shlex.quote(value)}")
PYEOF
)"

    if [ -n "$assignments" ]; then
        eval "$assignments"
    fi

    if [ -n "$DATA_DIR" ]; then
        DATA_DIR="$(resolve_scripts_training_path "$DATA_DIR")"
    else
        DATA_DIR="$SCRIPT_DIR/../$TRAIN_SCOPE/mcp_out"
    fi

    if [ -n "$QUALITY_GATE_PROFILE_FILE" ]; then
        QUALITY_GATE_PROFILE_FILE="$(resolve_scripts_training_path "$QUALITY_GATE_PROFILE_FILE")"
    fi

    if [ -n "$SYSTEM_PROMPT_FILE" ]; then
        SYSTEM_PROMPT_FILE="$(resolve_scripts_training_path "$SYSTEM_PROMPT_FILE")"
    fi
}

resolve_system_prompt_file() {
    if [ -n "$SYSTEM_PROMPT_FILE" ]; then
        if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
            echo "[ERROR] SYSTEM_PROMPT_FILE does not exist: $SYSTEM_PROMPT_FILE"
            exit 1
        fi
        echo "$SYSTEM_PROMPT_FILE"
        return
    fi

    local candidates=(
        "$SCRIPT_DIR/../$TRAIN_SCOPE/system_prompt.md"
        "$SCRIPT_DIR/../$TRAIN_SCOPE/${DATASET_BASE_NAME}_system_prompt.md"
        "$SCRIPT_DIR/../$TRAIN_SCOPE/${DATASET_BASE_NAME}_system_propmpt.md"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
}

compose_model_name() {
    local prefix="$1"
    local scope_suffix="${SERVER_SCOPE//_/-}"
    echo "${prefix}-${scope_suffix}${CONTRACT_MODEL_NAME_SUFFIX}"
}

get_system_prompt_json() {
    local prompt_file="$1"
    if [ -n "$prompt_file" ]; then
        "$PYTHON" - "$prompt_file" <<'PYEOF'
from pathlib import Path
import json
import sys

print(json.dumps(Path(sys.argv[1]).read_text(encoding="utf-8").strip(), ensure_ascii=False))
PYEOF
        return
    fi

    "$PYTHON" - <<'PYEOF'
import json

text = "You are a specialized MCP Agent with access to tools. When a user asks a question relevant to your tools, respond ONLY with a JSON tool call in this exact format: tool_call: {\"name\": \"<tool_name>\", \"arguments\": {...}}. Do not include any explanatory text. If no tool applies, respond naturally without tool_call prefix."
print(json.dumps(text, ensure_ascii=False))
PYEOF
}

# Stage switches (default: run full pipeline)
RUN_TRAIN=1
RUN_FUSE=1
RUN_MLX_TEST=0
RUN_GGUF=1
RUN_OLLAMA=1
RUN_HF_UPLOAD=0
RUN_GENERATE_CARD=0
RUN_QUALITY_GATE=1
RUN_DOWNLOAD_HF_ADAPTERS=0
QUALITY_GATE_TIMEOUT_SEC="${QUALITY_GATE_TIMEOUT_SEC:-120}"
QUALITY_GATE_NUM_PREDICT="${QUALITY_GATE_NUM_PREDICT:-128}"
QUALITY_GATE_RETRIES="${QUALITY_GATE_RETRIES:-3}"
QUALITY_GATE_PROFILE="${QUALITY_GATE_PROFILE:-$TRAIN_SCOPE}"
QUALITY_GATE_PROFILE_FILE="${QUALITY_GATE_PROFILE_FILE:-}"
ADAPTER_LAYOUT="unknown"   # auto-detected: mlx | peft

is_ollama_model_registered() {
    # ollama list usually reports names as "model:tag" (for example :latest).
    # Accept both exact model name and tagged variants.
    ollama list | awk 'NR>1 {print $1}' | grep -Eq "^${MODEL_NAME}(:.*)?$"
}

select_adapter_for_fuse() {
    # Priority:
    # 1) explicit --adapter-file
    # 2) explicit --adapter-iter
    # 3) Ministral fallback for skip-train runs: use earliest saved checkpoint
    local selected=""

    if [ -n "$ADAPTER_FILE_OVERRIDE" ]; then
        if [ ! -f "$ADAPTER_FILE_OVERRIDE" ]; then
            echo "[ERROR] --adapter-file does not exist: $ADAPTER_FILE_OVERRIDE"
            exit 1
        fi
        selected="$ADAPTER_FILE_OVERRIDE"
    elif [ -n "$ADAPTER_ITER_OVERRIDE" ]; then
        if ! echo "$ADAPTER_ITER_OVERRIDE" | grep -Eq '^[0-9]+$'; then
            echo "[ERROR] --adapter-iter must be an integer, got: $ADAPTER_ITER_OVERRIDE"
            exit 1
        fi
        local padded
        padded="$(printf '%07d' "$ADAPTER_ITER_OVERRIDE")"
        selected="$ADAPTER_PATH/${padded}_adapters.safetensors"
        if [ ! -f "$selected" ]; then
            echo "[ERROR] Requested adapter checkpoint not found: $selected"
            exit 1
        fi
    fi

    if [ -n "$selected" ]; then
        cp "$selected" "$ADAPTER_PATH/adapters.safetensors"
        echo "[INFO] Using adapter for fuse: $selected"
    fi
}

download_adapters_from_hf() {
    if [ -z "$HF_ADAPTER_REPO" ]; then
        echo "[ERROR] --download-hf-adapters requires a repo id like owner/repo"
        exit 1
    fi
    echo "[STEP] Downloading adapters from Hugging Face: $HF_ADAPTER_REPO (subdir=$HF_ADAPTER_SUBDIR)"
    "$PYTHON" "$PY_HELPERS_DIR/download_hf_adapters.py" \
        --repo "$HF_ADAPTER_REPO" \
        --subdir "$HF_ADAPTER_SUBDIR" \
        --dest "$ADAPTER_PATH"
    ADAPTER_LAYOUT="$($PYTHON "$PY_HELPERS_DIR/detect_adapter_layout.py" --path "$ADAPTER_PATH")"
    echo "[INFO] Downloaded adapters into: $ADAPTER_PATH"
}

detect_adapter_layout() {
    if ADAPTER_LAYOUT="$($PYTHON "$PY_HELPERS_DIR/detect_adapter_layout.py" --path "$ADAPTER_PATH" 2>/dev/null)"; then
        :
    else
        ADAPTER_LAYOUT="unknown"
    fi
}

fuse_peft_adapter_to_hf() {
    echo "[STEP] Merging PEFT adapter into full HF model"
    echo "[INFO] Base model: $FUSE_BASE_MODEL"
    echo "[INFO] Adapter dir: $ADAPTER_PATH"
    echo "[INFO] Save path : $FUSED_PATH"

    # Needed for Colab/PEFT adapter merge path.
    "$UV" pip install --python "$PYTHON" -U transformers peft accelerate safetensors torch
    "$PYTHON" "$PY_HELPERS_DIR/merge_peft_adapter.py" \
        --base-model "$FUSE_BASE_MODEL" \
        --adapter-dir "$ADAPTER_PATH" \
        --save-path "$FUSED_PATH"
}

resolve_dataset_files() {
    local split_output_dir="$DATA_DIR"
    local raw_jsonl="$DATA_DIR/train.jsonl"
    local split_train="$DATA_DIR/train_split.jsonl"
    local split_valid="$DATA_DIR/valid_split.jsonl"

    if { [ ! -f "$split_train" ] || [ ! -f "$split_valid" ]; } && [ -f "$raw_jsonl" ]; then
        echo "[STEP] Split files missing; creating train/valid split from $raw_jsonl"
        "$PYTHON" "$SCRIPT_DIR/../generate/py/train.py" \
            --output-dir "$split_output_dir" \
            --jsonl "$raw_jsonl" \
            --train-out "$split_train" \
            --valid-out "$split_valid" \
            --split
    fi

    if [ -z "$TRAIN_FILE" ]; then
        if [ -f "$DATA_DIR/train_split.jsonl" ]; then
            TRAIN_FILE="$DATA_DIR/train_split.jsonl"
        else
            TRAIN_FILE="$DATA_DIR/train.jsonl"
        fi
    fi
    if [ -z "$VALID_FILE" ]; then
        if [ -f "$DATA_DIR/valid_split.jsonl" ]; then
            VALID_FILE="$DATA_DIR/valid_split.jsonl"
        else
            VALID_FILE="$DATA_DIR/valid.jsonl"
        fi
    fi
}

run_dataset_preflight() {
    local train_path="$1"
    local valid_path="$2"

    if [ ! -f "$train_path" ]; then
        echo "[ERROR] Training file not found: $train_path"
        exit 1
    fi
    if [ ! -f "$valid_path" ]; then
        echo "[ERROR] Validation file not found: $valid_path"
        echo "[ERROR] Create split files first (train_split.jsonl + valid_split.jsonl)."
        exit 1
    fi

    if [ "$ALLOW_TRAIN_VALID_OVERLAP" -eq 1 ]; then
        "$PYTHON" "$PY_HELPERS_DIR/dataset_preflight.py" \
            --train "$train_path" \
            --valid "$valid_path" \
            --min-train-lines "$MIN_TRAIN_LINES" \
            --allow-overlap
    else
        "$PYTHON" "$PY_HELPERS_DIR/dataset_preflight.py" \
            --train "$train_path" \
            --valid "$valid_path" \
            --min-train-lines "$MIN_TRAIN_LINES"
    fi
}

prepare_training_data_dir() {
    local source_train="$1"
    local source_valid="$2"
    local system_prompt_file="$(resolve_system_prompt_file)"
    local prepare_args=()
    if [ -n "$system_prompt_file" ]; then
        prepare_args=(--system-prompt-file "$system_prompt_file")
    fi
    TRAIN_DATA_WORK_DIR="$SCRIPT_DIR/../.tmp_train_data_${MODEL_PRESET}"
    rm -rf "$TRAIN_DATA_WORK_DIR"
    mkdir -p "$TRAIN_DATA_WORK_DIR"
    "$PYTHON" "$PY_HELPERS_DIR/prepare_mlx_chat_data.py" \
        --input "$source_train" \
        --output "$TRAIN_DATA_WORK_DIR/train.jsonl" \
        "${prepare_args[@]}"
    "$PYTHON" "$PY_HELPERS_DIR/prepare_mlx_chat_data.py" \
        --input "$source_valid" \
        --output "$TRAIN_DATA_WORK_DIR/valid.jsonl" \
        "${prepare_args[@]}"
    if [ -n "$system_prompt_file" ]; then
        echo "[INFO] Using scope-specific system prompt: $system_prompt_file"
    else
        echo "[INFO] Using generic training system prompt"
    fi
    echo "[INFO] Prepared training data dir: $TRAIN_DATA_WORK_DIR"
}

run_prepared_data_preflight() {
    local allow_overlap_args=()
    local allow_truncation_args=()
    if [ "$ALLOW_TRAIN_VALID_OVERLAP" -eq 1 ]; then
        allow_overlap_args=(--allow-overlap)
    fi
    if [ "$ALLOW_SEQUENCE_TRUNCATION" -eq 1 ]; then
        allow_truncation_args=(--allow-truncation)
    fi

    "$PYTHON" "$PY_HELPERS_DIR/dataset_preflight.py" \
        --train "$TRAIN_DATA_WORK_DIR/train.jsonl" \
        --valid "$TRAIN_DATA_WORK_DIR/valid.jsonl" \
        --min-train-lines "$MIN_TRAIN_LINES" \
        --tokenizer-model "$TRAIN_BASE_MODEL" \
        --max-seq-length "$TRAIN_MAX_SEQ_LENGTH" \
        "${allow_overlap_args[@]}" \
        "${allow_truncation_args[@]}"
}

register_ollama_model_from_current_gguf() {
    local system_prompt_file="$(resolve_system_prompt_file)"
    local system_prompt_json="$(get_system_prompt_json "$system_prompt_file")"
    resolve_final_gguf_file
    if [ -z "$FINAL_GGUF_FILE" ]; then
        echo "[ERROR] No GGUF found for Ollama registration."
        echo "[ERROR] Expected one of: $GGUF_Q5 or $GGUF_F16"
        exit 1
    fi

    if [ "$FORCE_OLLAMA_RECREATE" -eq 1 ] && is_ollama_model_registered; then
        echo "[INFO] Removing existing Ollama model '$MODEL_NAME' to avoid stale artifact reuse"
        ollama rm "$MODEL_NAME" >/dev/null 2>&1 || true
    fi

    mkdir -p "$FUSED_PATH"
    # Build optional Modelfile sections
    # For ollama_native contracts the preset's ChatML TEMPLATE has no {{ .Tools }}
    # block; Ollama rejects /api/chat tool calls with HTTP 400 "does not support tools"
    # whenever the active template lacks that token.  Override with the tools-aware
    # ChatML Go template (used by Ollama's own qwen2.5 library models).
    if [ "$CONTRACT_TYPE" = "ollama_native" ]; then
        # shellcheck disable=SC2016  # {{ }} are Ollama Go template syntax, not bash
        OLLAMA_TEMPLATE='{{- if .Tools }}<|im_start|>system
{{ if .System }}{{ .System }}
{{ end }}# Tools
You may call one or more functions to assist with the user query.
You are provided with function signatures within <tools></tools> XML tags:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}{{- end }}
</tools>

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}</tool_call>
<|im_end|>
{{ else if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{- range .Messages }}{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ else if eq .Role "assistant" }}<|im_start|>assistant
{{ if .Content }}{{ .Content }}{{- else if .ToolCalls }}{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}</tool_call>
{{ end }}{{ end }}<|im_end|>
{{ else if eq .Role "tool" }}<|im_start|>user
<tool_response>
{{ .Content }}</tool_response>
<|im_end|>
{{ end }}{{ end }}{{- if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
{{ .Response }}<|im_end|>'
    fi
    if [ -n "$OLLAMA_TEMPLATE" ]; then
        OLLAMA_TEMPLATE_SECTION="TEMPLATE \"\"\"${OLLAMA_TEMPLATE}\"\"\""
    else
        OLLAMA_TEMPLATE_SECTION=""
    fi
    if [ "$OLLAMA_EMBED_SYSTEM_PROMPT" = "1" ]; then
        OLLAMA_SYSTEM_SECTION="# System prompt must match training-time prompt exactly for format compliance
SYSTEM $system_prompt_json"
    else
        OLLAMA_SYSTEM_SECTION="# System prompt intentionally omitted from Modelfile.
# Runtime clients inject the current system/tool prompt themselves, which avoids
# conflicting with native Ollama tool-calling behavior."
    fi
    cat <<EOF > "$FUSED_PATH/Modelfile"
FROM $(basename "$FINAL_GGUF_FILE")
${OLLAMA_TEMPLATE_SECTION}
${OLLAMA_SYSTEM_SECTION}
$OLLAMA_STOP_PARAMS
# Limit context window to reduce KV-cache memory pressure on Mac
PARAMETER num_ctx $OLLAMA_NUM_CTX
PARAMETER num_thread $OLLAMA_NUM_THREAD
EOF

    if [ -n "$system_prompt_file" ]; then
        echo "[INFO] Using scope-specific Ollama system prompt: $system_prompt_file"
    fi

    echo "[STEP] Registering Ollama model '$MODEL_NAME' from $(basename "$FINAL_GGUF_FILE")"
    ollama create "$MODEL_NAME" -f "$FUSED_PATH/Modelfile"

    if ! is_ollama_model_registered; then
        echo "[ERROR] Registration failed for '$MODEL_NAME'."
        exit 1
    fi
}

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Environment:
    SERVER_SCOPE          Logical MCP server scope name                         [default: weathersensorsmcp]
    MCP_SERVER            Backward-compatible alias for SERVER_SCOPE
    CONTRACT_TYPE         Training contract type                               [default: text_tool_call]
    TRAIN_SCOPE           Dataset scope folder under scripts_training/          [default: value of MCP_SERVER]
    MODEL_ARTIFACT_SCOPE  Adapter/fused model scope folder under scripts_training/ [default: value of TRAIN_SCOPE]
    SYSTEM_PROMPT_FILE    Optional custom system prompt markdown/text file used during training and Ollama packaging

Options:
    --full                  Run all stages (default)
    --only-train            Run only LoRA training
    --only-fuse             Run only adapter fuse
    --only-gguf             Run only GGUF conversion
    --only-ollama           Run only Ollama registration (requires existing GGUF)
    --skip-train            Skip LoRA training
    --skip-fuse             Skip adapter fuse
    --skip-gguf             Skip GGUF conversion
    --skip-ollama           Skip Ollama registration
    --upload-hf             Upload final GGUF and model card to Hugging Face
    --only-hf-upload        Run only Hugging Face upload (requires existing GGUF)
    --generate-card         Generate model card README (in addition to other stages)
    --only-generate-card    Generate model card README only (requires existing GGUF)
    --hf-repo <owner/repo>  Hugging Face model repo target
    --hf-private            Create repo as private (optional)
    --server-scope <name>   Override the logical server scope (for example: weathersensorsmcp)
    --contract-type <name>  Contract type (text_tool_call|ollama_native) [default: text_tool_call]
    --contract-config <path> Use an explicit contract config JSON file
    --preset <name>         Model preset (qwen3_4b|qwen2_5_3b|qwen2_5_1_5b)  [default: qwen3_4b]
                            Note: gemma4_e2b is Colab-only (VLM, not supported by mlx-lm)
    --resume-adapter        Resume from existing adapter in the preset-specific adapter folder
    --adapter-iter <n>      Fuse from checkpoint iteration n (e.g. 100 -> 0000100_adapters.safetensors)
    --adapter-file <path>   Fuse from an explicit adapters.safetensors file
    --skip-quality-gate     Skip local generation quality checks before upload
    --mlx-test              Run MLX-native generate test on fused model (before GGUF)
    --only-quality-gate     Run quality gate only (requires existing local Ollama model)
    --download-hf-adapters <owner/repo>   Download adapters from HF before fuse
    --hf-adapter-subdir <path>            Subdir inside HF repo containing adapters (default: adapters)
    -h, --help              Show this help

Examples:
    $(basename "$0") --skip-train
    $(basename "$0") --skip-train --skip-fuse
    $(basename "$0") --only-ollama
    $(basename "$0") --contract-type text_tool_call --preset qwen2_5_3b --skip-train
    $(basename "$0") --only-hf-upload --hf-repo your-user/tealkit-m4
    $(basename "$0") --preset qwen2_5_3b --skip-train
EOF
}

apply_model_preset() {
    case "$MODEL_PRESET" in
        gemma4_e2b)
            echo "[ERROR] gemma4_e2b is a multimodal VLM model — mlx_lm.lora cannot train it."
            echo "[ERROR] Use the Colab notebook (scripts_training/tealkit_training.ipynb) instead."
            exit 1
            ;;
        qwen3_4b)
            TRAIN_BASE_MODEL="mlx-community/Qwen3-4B-Instruct-2507-4bit"
            FUSE_BASE_MODEL="Qwen/Qwen3-4B"
            MODEL_NAME="$(compose_model_name "qwen3-4b")"
            # Qwen3 uses BPE tokenizer (tokenizer.json); no SentencePiece fixup needed.
            GGUF_EXTRA_ARGS=""
            FIX_MISTRAL_REGEX=0
            # Qwen3 uses the same ChatML format as Qwen2.5; stop tokens and template
            # must be declared explicitly so Ollama injects the system prompt correctly.
            OLLAMA_STOP_PARAMS='PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"'
            # shellcheck disable=SC2016
            OLLAMA_TEMPLATE='{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
{{ end }}'
            ;;
        qwen2_5_1_5b)
            TRAIN_BASE_MODEL="mlx-community/Qwen2.5-1.5B-Instruct-4bit"
            FUSE_BASE_MODEL="Qwen/Qwen2.5-1.5B-Instruct"
            MODEL_NAME="$(compose_model_name "qwen25-1p5b")"
            # ── Context window defaults ─────────────────────────────────────────
            # Qwen2.5-1.5B-Instruct supports up to 32K native context.
            # Default 8K; override via TRAIN_MAX_SEQ_LENGTH env var.
            # Supported values:
            #   8192   (8K)   — fits any Mac with 16GB+
            #   16384  (16K)  — fits M4 24GB+
            #   32768  (32K)  — native max, fits M4 48GB+ with grad checkpointing
            #   65536  (64K)  — requires RoPE extension (YaRN) and 64GB+
            if [ -z "$TRAIN_MAX_SEQ_LENGTH_WAS_SET" ]; then
                TRAIN_MAX_SEQ_LENGTH="8192"
            fi
            if [ -z "$OLLAMA_NUM_CTX_WAS_SET" ]; then
                OLLAMA_NUM_CTX="8192"
            fi
            # Qwen2.5 uses ChatML format; explicitly declare stop tokens in the Modelfile
            # so Ollama stops at <|im_end|> even when using /api/generate (raw completion).
            OLLAMA_STOP_PARAMS='PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"'
            # shellcheck disable=SC2016  # {{ }} are Ollama template syntax, not bash
            OLLAMA_TEMPLATE='{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
{{ end }}'
            ;;
        qwen2_5_3b)
            TRAIN_BASE_MODEL="mlx-community/Qwen2.5-3B-Instruct-4bit"
            FUSE_BASE_MODEL="Qwen/Qwen2.5-3B-Instruct"
            MODEL_NAME="$(compose_model_name "qwen2.5-3b")"
            if [ "$TRAIN_SCOPE" = "weathersensorsmcp" ] && [ -z "$TRAIN_ITERS_WAS_SET" ]; then
                if [ "$CONTRACT_TYPE" = "ollama_native" ]; then
                    # 1500 was too high and caused degeneration. Reduce to 800 for stability.
                    TRAIN_ITERS="800"
                else
                    # 500 iters is enough to teach tool selection without breaking the base
                    # model's native colon format (tool_call: {...}).
                    # Heavy training (1400 iters, 1e-4 LR) caused format regression to = style.
                    TRAIN_ITERS="500"
                fi
            fi
            if [ "$TRAIN_SCOPE" = "weathersensorsmcp" ] && [ -z "$TRAIN_LR_WAS_SET" ]; then
                if [ "$CONTRACT_TYPE" = "ollama_native" ]; then
                    # 2e-4 was too aggressive. Reduce to 5e-5 to prevent catastrophic forgetting.
                    TRAIN_LR="5e-5"
                else
                    # 5e-5 is conservative enough to preserve the base model's correct
                    # tool_call: {...} colon format while still teaching tool selection.
                    # 1e-4 was too aggressive and caused format regression after ~800 iters.
                    TRAIN_LR="5e-5"
                fi
            fi
            if [ -z "$TRAIN_MAX_SEQ_LENGTH_WAS_SET" ]; then
                case "$TRAIN_SCOPE" in
                    filesystem|git)
                        # Generic MCP tools — free, usable with any agentic app
                        TRAIN_MAX_SEQ_LENGTH="16384"
                        ;;
                    webcrawl|weatherforecast)
                        # Built-in TealKit MCP tools
                        TRAIN_MAX_SEQ_LENGTH="16384"
                        ;;
                    weathersensorsmcp)
                        # External proprietary MCP server tested with TealKit
                        TRAIN_MAX_SEQ_LENGTH="16384"
                        ;;
                    *)
                        TRAIN_MAX_SEQ_LENGTH="2048"
                        ;;
                esac
            fi
            if [ -z "$OLLAMA_NUM_CTX_WAS_SET" ]; then
                case "$TRAIN_SCOPE" in
                    filesystem|git)
                        # Generic MCP tools — free, usable with any agentic app
                        OLLAMA_NUM_CTX="16384"
                        ;;
                    webcrawl|weatherforecast)
                        # Built-in TealKit MCP tools
                        OLLAMA_NUM_CTX="16384"
                        ;;
                    weathersensorsmcp)
                        # External proprietary MCP server tested with TealKit
                        OLLAMA_NUM_CTX="16384"
                        ;;
                    *)
                        OLLAMA_NUM_CTX="2048"
                        ;;
                esac
            fi
            # Qwen2.5 uses ChatML format; explicitly declare stop tokens in the Modelfile
            # so Ollama stops at <|im_end|> even when using /api/generate (raw completion).
            OLLAMA_STOP_PARAMS='PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"'
            # Qwen2.5 GGUFs generated from hf-to-gguf often don't embed a recognised
            # Ollama template, causing Ollama to fall back to TEMPLATE {{ .Prompt }}
            # (raw completion).  That strips the ChatML system/user wrapper so the
            # SYSTEM block is never seen by the model.  Explicitly declare the ChatML
            # template so the system prompt and format rules are correctly injected.
            # shellcheck disable=SC2016  # {{ }} are Ollama template syntax, not bash
            OLLAMA_TEMPLATE='{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
{{ end }}'
            ;;
        *)
            echo "[ERROR] Unknown MODEL_PRESET: $MODEL_PRESET"
            echo "[ERROR] Supported presets: qwen3_4b, qwen2_5_3b, qwen2_5_1_5b  (gemma4_e2b → Colab only)"
            exit 1
            ;;
    esac
}

maybe_autoselect_existing_preset() {
    local current_has_artifacts=0
    local candidate_dir
    local candidate_preset
    local found_preset=""
    local found_count=0

    if [ -f "$ADAPTER_PATH/adapters.safetensors" ] || \
       { [ -f "$ADAPTER_PATH/adapter_model.safetensors" ] && [ -f "$ADAPTER_PATH/adapter_config.json" ]; } || \
       [ -f "$FUSED_PATH/config.json" ]; then
        current_has_artifacts=1
    fi

    if [ "$current_has_artifacts" -eq 1 ] || [ "$RUN_TRAIN" -eq 1 ] || [ "$MODEL_PRESET_EXPLICIT" -eq 1 ]; then
        return
    fi

    for candidate_dir in "$SCRIPT_DIR/$MODEL_ARTIFACT_SCOPE"/mcp_adapters_*; do
        [ -d "$candidate_dir" ] || continue
        if [ ! -f "$candidate_dir/adapters.safetensors" ] && \
           { [ ! -f "$candidate_dir/adapter_model.safetensors" ] || [ ! -f "$candidate_dir/adapter_config.json" ]; }; then
            continue
        fi

        candidate_preset="${candidate_dir##*/mcp_adapters_}"
        found_preset="$candidate_preset"
        found_count=$((found_count + 1))
    done

    if [ "$found_count" -eq 1 ] && [ -n "$found_preset" ] && [ "$found_preset" != "$MODEL_PRESET" ]; then
        echo "[INFO] No saved adapters found for preset '$MODEL_PRESET'."
        echo "[INFO] Auto-selecting saved preset '$found_preset' for skip-train workflow."
        MODEL_PRESET="$found_preset"
        apply_model_preset
        ADAPTER_PATH="$SCRIPT_DIR/$MODEL_ARTIFACT_SCOPE/mcp_adapters_${MODEL_PRESET}"
        FUSED_PATH="$SCRIPT_DIR/$MODEL_ARTIFACT_SCOPE/mcp_fused_model_${MODEL_PRESET}"
        GGUF_F16="$FUSED_PATH/${MODEL_NAME}-f16.gguf"
        GGUF_Q5="$FUSED_PATH/${MODEL_NAME}-q5_k_m.gguf"
    fi
}

set_only_mode() {
    RUN_TRAIN=0
    RUN_FUSE=0
    RUN_GGUF=0
    RUN_OLLAMA=0
    RUN_HF_UPLOAD=0
    RUN_GENERATE_CARD=0
    RUN_QUALITY_GATE=0
    case "$1" in
        train) RUN_TRAIN=1 ;;
        fuse) RUN_FUSE=1 ;;
        gguf) RUN_GGUF=1 ;;
        ollama) RUN_OLLAMA=1 ;;
        hfupload) RUN_HF_UPLOAD=1 ;;
        *)
            echo "[ERROR] Unknown only-mode: $1"
            exit 1
            ;;
    esac
}

resolve_final_gguf_file() {
    local candidate
    if [ -f "$GGUF_Q5" ]; then
        FINAL_GGUF_FILE="$GGUF_Q5"
    elif [ -f "$GGUF_F16" ]; then
        FINAL_GGUF_FILE="$GGUF_F16"
    else
        FINAL_GGUF_FILE=""
        for candidate in \
            "$FUSED_PATH"/*q5_k_m.gguf \
            "$FUSED_PATH"/*q4_k_m.gguf \
            "$FUSED_PATH"/*f16.gguf \
            "$FUSED_PATH"/*.gguf
        do
            if [ -f "$candidate" ]; then
                FINAL_GGUF_FILE="$candidate"
                echo "[INFO] Using existing GGUF artifact: $(basename "$candidate")"
                break
            fi
        done
    fi
}

validate_hf_repo_id() {
    local repo_id="$1"
    if [ -z "$repo_id" ]; then
        echo "[ERROR] HF repo is required for upload stage."
        echo "[ERROR] Provide with: --hf-repo <owner/repo>"
        exit 1
    fi

    if ! printf '%s' "$repo_id" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        echo "[ERROR] Invalid HF repo id: $repo_id"
        echo "[ERROR] Expected format: owner/repo"
        exit 1
    fi

    if printf '%s' "$repo_id" | grep -Eq '(^|/)(-|\.)|(--|\.\.)|(-|\.)$'; then
        echo "[ERROR] Invalid HF repo id: $repo_id"
        echo "[ERROR] Hugging Face repo names cannot start or end with '-' or '.', and cannot contain '--' or '..'."
        exit 1
    fi
}

is_adapter_compatible_for_resume() {
    local adapter_file="$1"
    local model_id="$2"

    "$PYTHON" "$PY_HELPERS_DIR/adapter_compatibility.py" --adapter-file "$adapter_file" --model-id "$model_id"
}

write_hf_model_card() {
    local card_path="$FUSED_PATH/README.md"
    local gguf_name quant_type hf_download_section
    gguf_name="$(basename "$FINAL_GGUF_FILE")"

    # Detect quantization from filename
    if echo "$gguf_name" | grep -qi "q5_k_m"; then
        quant_type="Q5_K_M (5-bit, recommended)"
    elif echo "$gguf_name" | grep -qi "q4_k_m"; then
        quant_type="Q4_K_M (4-bit, smaller)"
    elif echo "$gguf_name" | grep -qi "q4"; then
        quant_type="Q4"
    elif echo "$gguf_name" | grep -qi "f16"; then
        quant_type="F16 (unquantized, large)"
    else
        quant_type="unknown"
    fi

    # Build HuggingFace download instructions if HF_MODEL_REPO is set
    if [ -n "$HF_MODEL_REPO" ]; then
        hf_download_section="
### Option 2: Download from HuggingFace

\\\`\\\`\\\`bash
# 1. Download the GGUF and Modelfile to the same directory
curl -L -o $gguf_name https://huggingface.co/$HF_MODEL_REPO/resolve/main/$gguf_name
curl -L -o Modelfile https://huggingface.co/$HF_MODEL_REPO/resolve/main/Modelfile

# 2. Register with Ollama (creates local model from GGUF + Modelfile)
ollama create $MODEL_NAME -f Modelfile

# 3. Run the model
ollama run $MODEL_NAME
\\\`\\\`\\\`

**Important:** The \\\`Modelfile\\\` contains the required TEMPLATE directive for tool support.
Registering the GGUF without the Modelfile will result in \"does not support tools\" errors.
"
    else
        hf_download_section=""
    fi

    cat > "$card_path" <<EOF
---
license: apache-2.0
language:
- en
pipeline_tag: text-generation
tags:
- gguf
- ollama
- tool-calling
- mcp
- lora
base_model:
- $FUSE_BASE_MODEL
---

# $MODEL_NAME

> ⚠️ **This model is trained for the $MCP_SERVER MCP server.**
> It is optimised for structured MCP tool-call generation and is not intended
> to be a general-purpose assistant.

GGUF model fine-tuned for structured MCP tool-calling, ready for local inference via [Ollama](https://ollama.com).

## Model Details

| Property | Value |
|---|---|
| MCP server | $MCP_SERVER |
| Base model (training) | $TRAIN_BASE_MODEL |
| Base model (fused export) | $FUSE_BASE_MODEL |
| Fine-tune method | QLoRA / LoRA adapter fusion |
| Quantization | $quant_type |
| GGUF file | $gguf_name |
| Preset | $MODEL_PRESET |

## Intended Use

**Intended for agents or apps that call the $MCP_SERVER MCP server.**

The model was trained on a custom MCP tool-call JSONL dataset derived from the
server's tool schema. It is intended to emit structured JSON tool calls for
that server and is not suited for general chat.

## Quick Start (Ollama)

### Option 1: Direct from Ollama registry (if published)

\`\`\`bash
ollama pull $MODEL_NAME
ollama run $MODEL_NAME
\`\`\`
$hf_download_section
## Optional Links

- Docs: $GITHUB_PAGES_URL
- Source: $GITHUB_PROJECT_URL

## Files

- \`$gguf_name\`
- \`Modelfile\` — Ollama model definition with system prompt

## Notes

Produced via LoRA fine-tuning on Mac Apple Silicon (MLX), adapter fusion, and llama.cpp GGUF conversion.
See the [training guide]($GITHUB_TRAINING_GUIDE_URL) for full pipeline details.
EOF

    echo "[INFO] Wrote Hugging Face model card: $card_path"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --full)
            RUN_TRAIN=1; RUN_FUSE=1; RUN_GGUF=1; RUN_OLLAMA=1
            ;;
        --only-train)
            set_only_mode train
            ;;
        --only-fuse)
            set_only_mode fuse
            ;;
        --only-gguf)
            set_only_mode gguf
            ;;
        --only-ollama)
            set_only_mode ollama
            ;;
        --skip-train)
            RUN_TRAIN=0
            ;;
        --skip-fuse)
            RUN_FUSE=0
            ;;
        --skip-gguf)
            RUN_GGUF=0
            ;;
        --skip-ollama)
            RUN_OLLAMA=0
            ;;
        --upload-hf)
            RUN_HF_UPLOAD=1
            RUN_GENERATE_CARD=1
            ;;
        --only-hf-upload)
            set_only_mode hfupload
            ;;
        --generate-card)
            RUN_GENERATE_CARD=1
            ;;
        --only-generate-card)
            set_only_mode hfupload   # reuse hfupload's GGUF resolve
            RUN_HF_UPLOAD=0
            RUN_GENERATE_CARD=1
            ;;
        --hf-repo)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --hf-repo requires a value like owner/repo"
                exit 1
            fi
            HF_MODEL_REPO="$2"
            shift
            ;;
        --hf-private)
            HF_PRIVATE=1
            ;;
        --server-scope)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --server-scope requires a value"
                exit 1
            fi
            SERVER_SCOPE="$2"
            MCP_SERVER="$2"
            if [ -z "$TRAIN_SCOPE_WAS_SET" ]; then
                TRAIN_SCOPE="$2"
            fi
            if [ -z "$MODEL_ARTIFACT_SCOPE_WAS_SET" ]; then
                MODEL_ARTIFACT_SCOPE="$TRAIN_SCOPE"
            fi
            shift
            ;;
        --contract-type)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --contract-type requires a value"
                exit 1
            fi
            CONTRACT_TYPE="$2"
            shift
            ;;
        --contract-config)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --contract-config requires a path"
                exit 1
            fi
            CONTRACT_CONFIG_FILE="$2"
            shift
            ;;
        --preset)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --preset requires a value"
                exit 1
            fi
            MODEL_PRESET="$2"
            MODEL_PRESET_EXPLICIT=1
            shift
            ;;
        --resume-adapter)
            RESUME_IF_ADAPTER_EXISTS=1
            ;;
        --adapter-iter)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --adapter-iter requires an integer value"
                exit 1
            fi
            ADAPTER_ITER_OVERRIDE="$2"
            shift
            ;;
        --adapter-file)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --adapter-file requires a path"
                exit 1
            fi
            ADAPTER_FILE_OVERRIDE="$2"
            shift
            ;;
        --skip-quality-gate)
            RUN_QUALITY_GATE=0
            ;;
        --mlx-test)
            RUN_MLX_TEST=1
            ;;
        --only-quality-gate)
            set_only_mode hfupload
            RUN_HF_UPLOAD=0
            RUN_GENERATE_CARD=0
            RUN_QUALITY_GATE=1
            ;;
        --download-hf-adapters)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --download-hf-adapters requires owner/repo"
                exit 1
            fi
            RUN_DOWNLOAD_HF_ADAPTERS=1
            HF_ADAPTER_REPO="$2"
            shift
            ;;
        --hf-adapter-subdir)
            if [ $# -lt 2 ]; then
                echo "[ERROR] --hf-adapter-subdir requires a path"
                exit 1
            fi
            HF_ADAPTER_SUBDIR="$2"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
    shift
done

APPLIED_CONTRACT_CONFIG_FILE="$(resolve_contract_config_file)"
apply_contract_config "$APPLIED_CONTRACT_CONFIG_FILE"

apply_model_preset

# Use preset-specific output folders to avoid accidentally mixing adapters
# between model variants/runs. This prevents silent resume from stale state.
ADAPTER_PATH="$SCRIPT_DIR/$MODEL_ARTIFACT_SCOPE/mcp_adapters_${MODEL_PRESET}"
FUSED_PATH="$SCRIPT_DIR/$MODEL_ARTIFACT_SCOPE/mcp_fused_model_${MODEL_PRESET}"

# Recalculate GGUF paths now that MODEL_NAME is set by the preset
GGUF_F16="$FUSED_PATH/${MODEL_NAME}-f16.gguf"
GGUF_Q5="$FUSED_PATH/${MODEL_NAME}-q5_k_m.gguf"

maybe_autoselect_existing_preset

if [ ! -x "$PYTHON" ]; then
    echo "[ERROR] Venv not found at $VENV_BIN"
    echo "[ERROR] Run: bash scripts_training/bootstrap_venv_mac.sh"
    exit 1
fi

# MLX wheels are available for Apple Silicon arm64 only.
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
        echo "[ERROR] Detected architecture: $ARCH"
        echo "[ERROR] MLX/MLX-LM requires Apple Silicon arm64 wheels."
        echo "[ERROR] Start a native arm64 shell (not Rosetta), then recreate the venv."
        echo "[ERROR] Example: exec arch -arm64 zsh"
        exit 1
fi

echo "[STEP] Starting MCP Agent training workflow for Mac Mini M4"
echo "[INFO] Stages: train=$RUN_TRAIN fuse=$RUN_FUSE mlx_test=$RUN_MLX_TEST gguf=$RUN_GGUF ollama=$RUN_OLLAMA"
echo "[INFO] HF upload stage: $RUN_HF_UPLOAD"
echo "[INFO] Model preset: $MODEL_PRESET"
echo "[INFO] Server scope: $SERVER_SCOPE"
echo "[INFO] Contract type: $CONTRACT_TYPE"
if [ -n "$APPLIED_CONTRACT_CONFIG_FILE" ]; then
    echo "[INFO] Contract config: $APPLIED_CONTRACT_CONFIG_FILE"
fi
echo "[INFO] Training base model: $TRAIN_BASE_MODEL"
echo "[INFO] Fuse/export base model: $FUSE_BASE_MODEL"
echo "[INFO] Data dir: $DATA_DIR"
echo "[INFO] Adapter path: $ADAPTER_PATH"
echo "[INFO] Fused model path: $FUSED_PATH"
echo "[INFO] Quality gate: $RUN_QUALITY_GATE (timeout=${QUALITY_GATE_TIMEOUT_SEC}s/probe)"
echo "[INFO] Quality gate max tokens: $QUALITY_GATE_NUM_PREDICT"
echo "[INFO] Quality gate retries: $QUALITY_GATE_RETRIES"
echo "[INFO] Quality gate profile: $QUALITY_GATE_PROFILE"
if [ -n "$QUALITY_GATE_PROFILE_FILE" ]; then
    echo "[INFO] Quality gate profile file: $QUALITY_GATE_PROFILE_FILE"
fi
echo "[INFO] Force Ollama recreate: $FORCE_OLLAMA_RECREATE"
echo "[INFO] Train config: iters=$TRAIN_ITERS batch=$TRAIN_BATCH_SIZE grad_accum=$TRAIN_GRAD_ACCUM_STEPS max_seq=$TRAIN_MAX_SEQ_LENGTH grad_ckpt=$TRAIN_ENABLE_GRAD_CHECKPOINT lr=$TRAIN_LR"
echo "[INFO] Train prompt masking: $TRAIN_MASK_PROMPT"
echo "[INFO] License note: Gemma 4 license (see google/gemma-4-e2b-it on HF); Phi-4-mini is MIT; Qwen2.5 is Apache-2.0."

if [ "$RUN_TRAIN" -eq 1 ] || [ "$RUN_FUSE" -eq 1 ] || [ "$RUN_GGUF" -eq 1 ] || [ "$RUN_MLX_TEST" -eq 1 ]; then
    echo "[STEP] Updating MLX tools"
    "$UV" pip install --python "$PYTHON" -U mlx-lm
fi

if [ "$RUN_TRAIN" -eq 1 ]; then
    resolve_dataset_files
    run_dataset_preflight "$TRAIN_FILE" "$VALID_FILE"
    prepare_training_data_dir "$TRAIN_FILE" "$VALID_FILE"
    run_prepared_data_preflight
fi

if [ "$RUN_TRAIN" -eq 1 ]; then
    echo "[STEP] Verifying training base model setting"
    if echo "$TRAIN_BASE_MODEL" | grep -qi "gguf"; then
        echo "[ERROR] TRAIN_BASE_MODEL appears to be GGUF-based: $TRAIN_BASE_MODEL"
        echo "[ERROR] Use an MLX model repo for training, e.g.: mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        exit 1
    fi
    echo "[INFO] Training model setting looks valid. mlx_lm will fetch or cache it as needed."
fi

if [ "$RUN_FUSE" -eq 1 ]; then
    echo "[STEP] Verifying fuse or export base model setting"
    if echo "$FUSE_BASE_MODEL" | grep -qi "gguf"; then
        echo "[ERROR] FUSE_BASE_MODEL appears to be GGUF-based: $FUSE_BASE_MODEL"
        echo "[ERROR] Use a full HF model repo for fuse/export, e.g.: Qwen/Qwen2.5-1.5B-Instruct"
        exit 1
    fi
    echo "[INFO] Fuse model setting looks valid. mlx_lm will fetch or cache it as needed."
fi

if [ "$RUN_TRAIN" -eq 1 ]; then
    # mlx_lm.lora does not accept --rank; LoRA rank must be set via -c config JSON.
    # Note: macOS mktemp does not support suffix after XXXXXX, so use no extension.
    LORA_CONFIG_JSON="$(mktemp /tmp/mlx_lora_config_XXXXXX)"
    printf '{"lora_parameters":{"rank":%s,"scale":20.0,"dropout":0.0}}' "$TRAIN_LORA_RANK" > "$LORA_CONFIG_JSON"

    TRAIN_CMD=(
        "$VENV_BIN/mlx_lm.lora"
        --model "$TRAIN_BASE_MODEL"
        --train
        --data "$TRAIN_DATA_WORK_DIR"
        --iters "$TRAIN_ITERS"
        --batch-size "$TRAIN_BATCH_SIZE"
        --grad-accumulation-steps "$TRAIN_GRAD_ACCUM_STEPS"
        --max-seq-length "$TRAIN_MAX_SEQ_LENGTH"
        --adapter-path "$ADAPTER_PATH"
        --learning-rate "$TRAIN_LR"
        --num-layers "$TRAIN_NUM_LAYERS"
        -c "$LORA_CONFIG_JSON"
    )

    if [ "$TRAIN_MASK_PROMPT" -eq 1 ]; then
        TRAIN_CMD+=(--mask-prompt)
    fi

    if [ "$TRAIN_ENABLE_GRAD_CHECKPOINT" -eq 1 ]; then
        TRAIN_CMD+=(--grad-checkpoint)
    fi

    if [ "$RESUME_IF_ADAPTER_EXISTS" -eq 1 ] && [ -f "$ADAPTER_PATH/adapters.safetensors" ]; then
        echo "[INFO] Found existing adapter. Checking compatibility with preset: $MODEL_PRESET"
        set +e
        COMPAT_OUTPUT="$(is_adapter_compatible_for_resume "$ADAPTER_PATH/adapters.safetensors" "$TRAIN_BASE_MODEL" 2>&1)"
        COMPAT_STATUS=$?
        set -e
        if [ "$COMPAT_STATUS" -eq 0 ]; then
            echo "[INFO] Resume adapter is compatible. Resuming from $ADAPTER_PATH/adapters.safetensors"
            TRAIN_CMD+=(--resume-adapter-file "$ADAPTER_PATH/adapters.safetensors")
        elif [ "$COMPAT_STATUS" -eq 10 ]; then
            echo "[WARN] Existing adapter is incompatible with current preset. Starting fresh training."
            echo "[WARN] Details: $COMPAT_OUTPUT"
            echo "[WARN] Tip: move old adapter aside (e.g. mcp_adapters/adapters_3b.safetensors) or train in preset-specific folders."
        else
            echo "[WARN] Could not verify adapter compatibility. Starting fresh training for safety."
            echo "[WARN] Details: $COMPAT_OUTPUT"
        fi
    fi

    echo "[STEP] Training LoRA adapter"
    "${TRAIN_CMD[@]}"
else
    echo "[INFO] Skipping training stage."
fi

if [ "$RUN_DOWNLOAD_HF_ADAPTERS" -eq 1 ]; then
    download_adapters_from_hf
fi

if [ "$RUN_FUSE" -eq 1 ]; then
    select_adapter_for_fuse
    detect_adapter_layout
    if [ "$ADAPTER_LAYOUT" = "unknown" ]; then
        echo "[ERROR] Missing supported adapter files in: $ADAPTER_PATH"
        echo "[ERROR] Expected either MLX (adapters.safetensors) or PEFT (adapter_model.safetensors + adapter_config.json)."
        echo "[ERROR] If you trained another preset, rerun with --preset <name>."
        echo "[ERROR] Available adapter dirs in this scope:"
        find "$SCRIPT_DIR/$MODEL_ARTIFACT_SCOPE" -maxdepth 1 -type d -name 'mcp_adapters_*' -print | sed 's#^.*/mcp_adapters_#  - #' || true
        exit 1
    fi
    echo "[INFO] Adapter layout: $ADAPTER_LAYOUT"

    if [ "$ADAPTER_LAYOUT" = "mlx" ]; then
        echo "[STEP] Fusing MLX adapter into a new model file"
        "$VENV_BIN/mlx_lm.fuse" \
            --model "$FUSE_BASE_MODEL" \
            --adapter-path "$ADAPTER_PATH" \
            --save-path "$FUSED_PATH"

    else
        fuse_peft_adapter_to_hf
    fi
else
    echo "[INFO] Skipping fuse stage."
fi

if [ "$RUN_MLX_TEST" -eq 1 ]; then
    if [ ! -f "$FUSED_PATH/config.json" ]; then
        echo "[ERROR] MLX test requires a fused model at $FUSED_PATH (run fuse stage first)"
        exit 1
    fi

    echo "[STEP] Running MLX-native generate test on fused model"
    MLX_TEST_TMPFILE="$(mktemp /tmp/mlx_test_out.XXXXXX)"
    MLX_TEST_ARGS=(--model-path "$FUSED_PATH" --out-file "$MLX_TEST_TMPFILE")
    "$PYTHON" "$PY_HELPERS_DIR/mlx_generate_test.py" "${MLX_TEST_ARGS[@]}"
    MLX_PY_STATUS=$?
    echo "[MLX-TEST] --- raw output above ---"
    if [ "$MLX_PY_STATUS" -ne 0 ]; then
        echo "[MLX-TEST] FAIL: mlx_lm Python API raised an exception (see above)"
        rm -f "$MLX_TEST_TMPFILE"
        exit 1
    fi

    "$PYTHON" "$PY_HELPERS_DIR/mlx_output_check.py" --file "$MLX_TEST_TMPFILE"
    MLX_TEST_STATUS=$?
    rm -f "$MLX_TEST_TMPFILE"
    if [ "$MLX_TEST_STATUS" -ne 0 ]; then
        echo "[MLX-TEST] FAIL: Fused model output appears degenerate."
        echo "[MLX-TEST] Possible causes:"
        echo "[MLX-TEST]   1. Adapter overfit / collapsed — try fewer TRAIN_ITERS or lower TRAIN_LR"
        echo "[MLX-TEST]   2. Training data format mismatch (chat template vs raw text)"
        echo "[MLX-TEST] GGUF and publish stages are blocked. Re-train or inspect the adapter."
        exit 1
    fi
    echo "[MLX-TEST] Fused model output is healthy – proceeding."
else
    echo "[INFO] Skipping MLX test stage (add --mlx-test to enable)."
fi

if [ "$RUN_GGUF" -eq 1 ]; then
    if [ ! -f "$FUSED_PATH/config.json" ]; then
        echo "[ERROR] Missing fused model config at $FUSED_PATH/config.json"
        if [ -f "$ADAPTER_PATH/adapters.safetensors" ]; then
            echo "[ERROR] You have adapters, but no fused model yet."
            echo "[ERROR] Re-run with fuse enabled: bash scripts_training/train/train_mcp.sh --skip-train"
        else
            echo "[ERROR] No adapters found at $ADAPTER_PATH/adapters.safetensors"
            echo "[ERROR] Run full training first: bash scripts_training/train/train_mcp.sh"
        fi
        exit 1
    fi

    echo "[STEP] Converting fused model to GGUF for Ollama"
        if ! git -C "$LLAMA_CPP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || [ ! -f "$LLAMA_CPP_DIR/convert_hf_to_gguf.py" ]; then
            echo "[INFO] Preparing fresh llama.cpp checkout at $LLAMA_CPP_DIR"
            rm -rf "$LLAMA_CPP_DIR"
            git clone https://github.com/ggerganov/llama.cpp "$LLAMA_CPP_DIR"
    else
            echo "[INFO] Updating llama.cpp to latest (fetch + hard reset)..."
            # Use fetch + hard reset instead of pull --ff-only so we always get the latest
            # version even if the local clone has detached HEAD or local modifications.
            # This is important for phi3/phi4-mini tiktoken support added in recent commits.
            LLAMA_BRANCH=$(git -C "$LLAMA_CPP_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "master")
            git -C "$LLAMA_CPP_DIR" fetch origin || echo "[WARN] llama.cpp fetch failed"
            git -C "$LLAMA_CPP_DIR" reset --hard "origin/${LLAMA_BRANCH}" || \
                git -C "$LLAMA_CPP_DIR" reset --hard origin/master || \
                echo "[WARN] llama.cpp reset failed — using existing version"
    fi

    echo "[INFO] Installing llama.cpp converter dependencies..."
    if [ -f "$LLAMA_CPP_DIR/requirements.txt" ]; then
        if ! "$UV" pip install --python "$PYTHON" --index-strategy unsafe-best-match -r "$LLAMA_CPP_DIR/requirements.txt"; then
            echo "[WARN] Failed to install llama.cpp requirements with uv resolver."
            echo "[WARN] Retrying with a minimal converter dependency set in the venv"
            "$UV" pip install --python "$PYTHON" -U numpy sentencepiece protobuf safetensors transformers huggingface-hub tqdm
        fi
    else
        echo "[WARN] llama.cpp requirements.txt not found — installing minimal converter dependency set"
        "$UV" pip install --python "$PYTHON" -U numpy sentencepiece protobuf safetensors transformers huggingface-hub tqdm
    fi

    if [ ! -f "$LLAMA_CPP_DIR/conversion/__init__.py" ]; then
        echo "[ERROR] llama.cpp conversion package is incomplete: missing conversion/__init__.py"
        echo "[ERROR] Remove $LLAMA_CPP_DIR and rerun the script."
        exit 1
    fi

    # Refresh tokenizer files in the fused model dir from the full HF base model
    # (mlx_lm.fuse copies from the 4-bit MLX cache which may have incomplete metadata).
    # For BPE/tiktoken models (Phi-4-mini, Qwen): tokenizer.json is sufficient.
    echo "[INFO] Refreshing tokenizer files in fused model dir from $FUSE_BASE_MODEL..."
    "$PYTHON" - "$FUSED_PATH" "$FUSE_BASE_MODEL" <<'PYEOF'
import sys, os, shutil, glob

fused_path = sys.argv[1]
fuse_base  = sys.argv[2]

# Refresh core tokenizer config files from the full base model so llama.cpp sees the
# correct tokenizer_class / vocab_type rather than whatever mlx_lm.fuse copied.
try:
    from huggingface_hub import hf_hub_download
    for fname in ("tokenizer_config.json", "tokenizer.json", "special_tokens_map.json"):
        try:
            src = hf_hub_download(repo_id=fuse_base, filename=fname)
            shutil.copy2(src, os.path.join(fused_path, fname))
            print(f"[INFO] refreshed {fname} from {fuse_base}", flush=True)
        except Exception as e:
            print(f"[INFO] {fname} not found in {fuse_base} ({e}) — skipping", flush=True)
except ImportError:
    print("[WARN] huggingface_hub not available; skipping tokenizer refresh", flush=True)

# For SPM models, also try to fetch tokenizer.model
dest_spm = os.path.join(fused_path, "tokenizer.model")
if not os.path.exists(dest_spm):
    # Try HF download
    try:
        from huggingface_hub import hf_hub_download
        src = hf_hub_download(repo_id=fuse_base, filename="tokenizer.model")
        shutil.copy2(src, dest_spm)
        print(f"[INFO] tokenizer.model fetched from {fuse_base}", flush=True)
    except Exception:
        # Try local HF cache
        model_slug = fuse_base.replace("/", "--")
        cache_root = os.path.expanduser("~/.cache/huggingface/hub")
        pattern    = os.path.join(cache_root, f"models--{model_slug}", "snapshots", "*", "tokenizer.model")
        matches    = glob.glob(pattern)
        if matches:
            shutil.copy2(matches[0], dest_spm)
            print(f"[INFO] tokenizer.model found in local HF cache", flush=True)
        else:
            print(f"[INFO] tokenizer.model not available for {fuse_base} — expected for BPE/tiktoken models", flush=True)
PYEOF


      echo "[INFO] Creating F16 GGUF..."
      if ! "$PYTHON" "$LLAMA_CPP_DIR/convert_hf_to_gguf.py" \
          "$FUSED_PATH" \
          --outfile "$GGUF_F16" \
          --outtype f16 \
          ${GGUF_EXTRA_ARGS:-}; then
          echo "[ERROR] GGUF conversion failed."
          echo "[ERROR] This often happens if fusion was done from a quantized base model."
          echo "[ERROR] Current script defaults fuse to full HF model ($FUSE_BASE_MODEL)."
          echo "[ERROR] Re-run: bash scripts_training/train/train_mcp.sh --skip-train"
          exit 1
      fi

    if command -v llama-quantize >/dev/null 2>&1; then
            echo "[INFO] Quantizing GGUF to Q5_K_M..."
            llama-quantize "$GGUF_F16" "$GGUF_Q5" Q5_K_M
    else
            echo "[WARN] llama-quantize not found (install via: brew install llama.cpp)."
            echo "[WARN] Q5 quantization skipped. Will use F16 GGUF for Ollama."
    fi
else
    echo "[INFO] Skipping GGUF conversion stage."
fi

if [ "$RUN_OLLAMA" -eq 1 ]; then
    register_ollama_model_from_current_gguf
else
    echo "[INFO] Skipping Ollama registration stage."
fi

if [ "$RUN_QUALITY_GATE" -eq 1 ]; then
    echo "[STEP] Running local model quality gate"
    if ! command -v ollama >/dev/null 2>&1; then
        echo "[ERROR] ollama not found. Quality gate requires local model execution."
        echo "[ERROR] Install Ollama or rerun with --skip-quality-gate (not recommended for publish)."
        exit 1
    fi

    if ! is_ollama_model_registered || [ "$FORCE_OLLAMA_RECREATE" -eq 1 ]; then
        echo "[INFO] Ensuring quality gate uses current GGUF artifact"
        register_ollama_model_from_current_gguf
    fi

    QUALITY_GATE_ARGS=(
        --model "$MODEL_NAME"
        --timeout "$QUALITY_GATE_TIMEOUT_SEC"
        --num-ctx "$OLLAMA_NUM_CTX"
        --num-predict "$QUALITY_GATE_NUM_PREDICT"
        --retries "$QUALITY_GATE_RETRIES"
    )

    if [ -n "$QUALITY_GATE_PROFILE_FILE" ]; then
        QUALITY_GATE_ARGS+=(--profile-file "$QUALITY_GATE_PROFILE_FILE")
    else
        QUALITY_GATE_ARGS+=(--profile "$QUALITY_GATE_PROFILE")
    fi

    RESOLVED_SYSTEM_PROMPT_FILE="$(resolve_system_prompt_file)"
    if [ -n "$RESOLVED_SYSTEM_PROMPT_FILE" ] && [ -f "$RESOLVED_SYSTEM_PROMPT_FILE" ]; then
        QUALITY_GATE_ARGS+=(--system-prompt-file "$RESOLVED_SYSTEM_PROMPT_FILE")
    fi

    "$PYTHON" "$SCRIPT_DIR/../quality_gate/py/quality_gate.py" "${QUALITY_GATE_ARGS[@]}"
else
    echo "[INFO] Skipping quality gate stage."
fi

if [ "$RUN_GENERATE_CARD" -eq 1 ] && [ "$RUN_HF_UPLOAD" -eq 0 ]; then
    # Standalone card generation (--only-generate-card or --generate-card without upload)
    resolve_final_gguf_file
    if [ -z "$FINAL_GGUF_FILE" ]; then
        echo "[ERROR] No GGUF found for card generation."
        echo "[ERROR] Expected one of: $GGUF_Q5 or $GGUF_F16"
        exit 1
    fi
    write_hf_model_card
fi

if [ "$RUN_HF_UPLOAD" -eq 1 ]; then
    if [ -z "$HF_MODEL_REPO" ]; then
        echo "[ERROR] --hf-repo <owner/repo> is required for HF upload."
        exit 1
    fi
    resolve_final_gguf_file
    if [ -z "$FINAL_GGUF_FILE" ]; then
        echo "[ERROR] No GGUF found for HF upload."
        echo "[ERROR] Expected one of: $GGUF_Q5 or $GGUF_F16"
        exit 1
    fi
    write_hf_model_card
    echo "[STEP] Uploading GGUF + Modelfile + README to Hugging Face: $HF_MODEL_REPO"
    PRIVATE_FLAG="$HF_PRIVATE"
    "$PYTHON" - <<PYEOF
import sys, os
try:
    from huggingface_hub import HfApi
except ImportError:
    print("[ERROR] huggingface_hub not installed. Run: pip install huggingface_hub")
    sys.exit(1)

api = HfApi()
repo_id = "${HF_MODEL_REPO}"
private = bool(int("${PRIVATE_FLAG}"))
fused_path = "${FUSED_PATH}"
gguf_file = "${FINAL_GGUF_FILE}"
model_name = "${MODEL_NAME}"

# Create repo if it doesn't exist
try:
    api.create_repo(repo_id=repo_id, repo_type="model", private=private, exist_ok=True)
    print(f"[INFO] Repo ready: https://huggingface.co/{repo_id}")
except Exception as e:
    print(f"[ERROR] Could not create/access repo {repo_id}: {e}")
    sys.exit(1)

# Upload GGUF
gguf_name = os.path.basename(gguf_file)
print(f"[INFO] Uploading {gguf_name} ...")
api.upload_file(path_or_fileobj=gguf_file, path_in_repo=gguf_name,
                repo_id=repo_id, repo_type="model",
                commit_message=f"Upload {gguf_name}")
print(f"[INFO] Uploaded {gguf_name}")

# Upload Modelfile
modelfile_path = os.path.join(fused_path, "Modelfile")
if os.path.isfile(modelfile_path):
    api.upload_file(path_or_fileobj=modelfile_path, path_in_repo="Modelfile",
                    repo_id=repo_id, repo_type="model",
                    commit_message="Upload Modelfile")
    print("[INFO] Uploaded Modelfile")

# Upload README / model card
readme_path = os.path.join(fused_path, "README.md")
if os.path.isfile(readme_path):
    api.upload_file(path_or_fileobj=readme_path, path_in_repo="README.md",
                    repo_id=repo_id, repo_type="model",
                    commit_message="Upload model card")
    print("[INFO] Uploaded README.md")

print(f"[INFO] HF upload complete: https://huggingface.co/{repo_id}")
PYEOF
fi