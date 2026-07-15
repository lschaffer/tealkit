# scripts_training Agent Instructions

## Goal

Provide an instruction file that can recreate a similar (not necessarily identical) training workspace for MCP tool-calling model fine-tuning.

### Server Scopes (training domains)

Five server scopes are supported, grouped by category:

| Scope | Tools | Category | Description |
|---|---|---|---|
| `filesystem` | File system tools | Generic MCP — free, usable with any agentic app | File system read/write/edit operations |
| `git` | Git tools | Generic MCP — free, usable with any agentic app | Git repository management |
| `webcrawl` | 6 website search tools | TealKit inbuilt | Website indexing, search, page listing, content retrieval |
| `weatherforecast` | N weather forecast tools | TealKit inbuilt | Weather forecast-specific tools |
| `weathersensorsmcp` | 18 weather/sensor tools | External (proprietary) tested with TealKit | Weather station data, device lookup, measurements, forecasts, charts |

Primary model targets:
- Qwen2.5-3B (`qwen2_5_3b` preset)
- Qwen3-4B (`qwen3_4b` preset)
- Ministral-3B (`ministral_3b` preset)

Primary generator model:
- DeepSeek (default, via `EXAMPLE_GEN_PROVIDER=deepseek`)
- Gemini (via `EXAMPLE_GEN_PROVIDER=gemini`)
- Any OpenAI-compatible endpoint (via `EXAMPLE_GEN_PROVIDER=openai_compatible`)

---

## Contract Types

There are two contract types that determine the format of tool-calling data:

### `text_tool_call` (legacy)
- Assistant tool call is a plain text string: `tool_call: {"name": "...", "arguments": {...}}`
- Ollama model name suffix: *(none)*

### `ollama_native`
- Assistant tool call uses Ollama's native structured format: `{"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "...", "arguments": {...}}}]}`
- Ollama model name suffix: `-ollama`
- The Modelfile TEMPLATE must contain `{{ .Tools }}` for Ollama to accept `/api/chat` requests with a `tools:` parameter. `train_mcp.sh` injects a tools-aware ChatML Go template automatically for `ollama_native` contracts.

---

## Folder-Level Structure

```
scripts_training/
  bootstrap_venv_mac.sh          # Recreate .venv (must re-run after project folder moves)
  download_mlx_models_mac.sh     # Download MLX model weights for local training

  contracts/
    text_tool_call/              # Shared prompt contract and quality gate profile
    ollama_native/               # Shared prompt contract and quality gate profile
    weatherforecast/
      text_tool_call/            # Weatherforecast-specific prompt contract + quality gate
      ollama_native/
    webcrawl/
      text_tool_call/            # Webcrawl-specific prompt contract + quality gate
      ollama_native/

  servers/
    weathersensorsmcp/
      configs/
        text_tool_call/config.json
        ollama_native/config.json
      datasets/
        ollama_native/           # train.jsonl, train_split.jsonl, valid_split.jsonl
      outputs/
        ollama_native/           # Trained adapter, fused model, GGUF, Modelfile
      prompts/
        weather_sensors_system_prompt.md
        ollama_native_system_prompt.md

    weatherforecast/
      configs/
        text_tool_call/config.json
        ollama_native/config.json
      datasets/
        text_tool_call/          # Generated train.jsonl (if generated)
        ollama_native/           # Generated train.jsonl (if generated)
      outputs/
        text_tool_call/          # Trained adapter, GGUF, Modelfile (if trained)
        ollama_native/
      prompts/
        weatherforecast_system_prompt.md
        ollama_native_system_prompt.md

    webcrawl/
      configs/
        text_tool_call/config.json
        ollama_native/config.json
      datasets/
        text_tool_call/          # train.jsonl, train_split.jsonl, valid_split.jsonl
        ollama_native/           # Generated train.jsonl (if generated)
      outputs/
        text_tool_call/          # Trained adapter, GGUF, Modelfile (if trained)
        ollama_native/
      prompts/
        webcrawl_system_prompt.md
        ollama_native_system_prompt.md

  weathersensorsmcp/
    mcp_data/                    # Tool schemas (weather_sensors_tools.jsonl)
    mcp_out/                     # text_tool_call generated data (transient, not committed)

  weatherforecast/
    weather_tools.jsonl          # Tool schema for weatherforecast domain

  webcrawl/
    website_search_tools.jsonl   # Tool schema for webcrawl domain

  generate/
    weathersensorsmcp/
      run_generate.sh                        # text_tool_call, full generation
      run_generate_incremental.sh            # text_tool_call, incremental top-up
      run_generate_ministral.sh              # text_tool_call, Ministral variant
      run_generate_ministral_incremental.sh
      run_generate_ollama_native.sh          # ollama_native, full generation
      run_generate_ollama_native_incremental.sh  # ollama_native, incremental top-up
      run_generate_contract.sh               # Shared dispatcher (reads SERVER_SCOPE + CONTRACT_TYPE env vars)
    webcrawl/
      run_generate.sh                        # text_tool_call (delegates to run_generate_contract.sh)
      run_generate_ollama_native.sh          # ollama_native
      run_generate_incremental.sh
      run_generate_ollama_native_incremental.sh
    weatherforecast/
      run_generate.sh                        # text_tool_call (delegates to run_generate_contract.sh)
      run_generate_ollama_native.sh          # ollama_native
      run_generate_incremental.sh
      run_generate_ollama_native_incremental.sh
    py/
      generate_train_jsonl_gemini.py         # Single-pass generator
      generate_train_jsonl_gemini_incremental.py  # Chunked/incremental generator (also has --repair-only)
      training_data_augment.py               # Re-export of common/py/dataset/training_data_augment.py

  train/
    train_mcp.sh                 # Full pipeline: train → fuse → GGUF → Ollama register → quality gate
                                 # Flags: --contract-type, --preset, --only-train, --only-fuse,
                                 #        --only-gguf, --only-ollama, --only-quality-gate,
                                 #        --server-scope (weathersensorsmcp|webcrawl|weatherforecast)
    upload_gguf_to_tealkit.sh    # Upload GGUF to HuggingFace

  quality_gate/
    py/quality_gate_core.py      # Sends /api/chat with tools, validates ollama_native_tool_call response
    run_qwen3_quality_gate.sh
    run_ministral_quality_gate.sh

  common/
    py/
      dataset/
        gemini_generation_common.py   # normalize_training_row, has_parseable_tool_call, etc.
        validate_jsonl.py             # Validates JSONL against contract type
        train_dataset_cli.py          # Dedup, split, prepare
        training_data_augment.py      # prepare_training_lines, synthesize_followup_rows (domain-aware)

  notebooks/
    text_tool_call/
      weathersensorsmcp_qwen_train.ipynb     # Colab: Qwen3-4B, text_tool_call
      weathersensorsmcp_ministral_train.ipynb
      weatherforecast_qwen_train.ipynb
      webcrawl_qwen_train.ipynb
    ollama_native/
      weathersensorsmcp_qwen_train.ipynb     # Colab: Qwen3-4B, ollama_native
      weathersensorsmcp_ministral_train.ipynb
      weatherforecast_qwen_train.ipynb
      webcrawl_qwen_train.ipynb
```

---

## Data Generation

### Environment variables
| Variable | Default | Description |
|---|---|---|
| `EXAMPLE_GEN_PROVIDER` | `deepseek` | `deepseek`, `gemini`, or `openai_compatible` |
| `DEEPSEEK_API_KEY` | — | Required for DeepSeek |
| `GEMINI_API_KEY` | — | Required for Gemini |
| `GEMINI_MODEL` | provider default | e.g. `gemini-2.5-pro` |
| `SERVER_SCOPE` | `weathersensorsmcp` | Which server/tools to generate for (`weathersensorsmcp`, `webcrawl`, `weatherforecast`) |
| `CONTRACT_TYPE` | `text_tool_call` | Set by the named wrapper scripts |
| `TOTAL` | `1500` (incremental) | Target line count |
| `INCREMENTAL` | `0` | Set to `1` for top-up mode |
| `COUNT` | `360` | Target examples (non-incremental) |
| `MIN_VALID` | `300` | Minimum valid lines required |

### Typical commands — weathersensorsmcp (18 tools)
```bash
# Generate text_tool_call data
DEEPSEEK_API_KEY=... bash scripts_training/generate/weathersensorsmcp/run_generate.sh

# Generate ollama_native data (full)
DEEPSEEK_API_KEY=... bash scripts_training/generate/weathersensorsmcp/run_generate_ollama_native.sh

# Top-up ollama_native data with Gemini
EXAMPLE_GEN_PROVIDER=gemini GEMINI_API_KEY=... TOTAL=1200 \
  bash scripts_training/generate/weathersensorsmcp/run_generate_ollama_native_incremental.sh

# Repair existing ollama_native JSONL (re-normalize + drop bad rows, no new generation)
scripts_training/.venv/bin/python \
  scripts_training/generate/py/generate_train_jsonl_gemini_incremental.py \
  --repair-only \
  --prompt scripts_training/servers/weathersensorsmcp/datasets/ollama_native/generated_train_prompt.md \
  --out scripts_training/servers/weathersensorsmcp/datasets/ollama_native/train.jsonl \
  --tools scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl \
  --contract-type ollama_native
```

### Typical commands — webcrawl (6 tools)
```bash
# Generate text_tool_call data
DEEPSEEK_API_KEY=... bash scripts_training/generate/webcrawl/run_generate.sh

# Generate ollama_native data (full)
DEEPSEEK_API_KEY=... bash scripts_training/generate/webcrawl/run_generate_ollama_native.sh

# Top-up with Gemini
EXAMPLE_GEN_PROVIDER=gemini GEMINI_API_KEY=... TOTAL=600 \
  bash scripts_training/generate/webcrawl/run_generate_ollama_native_incremental.sh

# Repair existing JSONL
scripts_training/.venv/bin/python \
  scripts_training/generate/py/generate_train_jsonl_gemini_incremental.py \
  --repair-only \
  --prompt scripts_training/servers/webcrawl/datasets/ollama_native/generated_train_prompt.md \
  --out scripts_training/servers/webcrawl/datasets/ollama_native/train.jsonl \
  --tools scripts_training/webcrawl/website_search_tools.jsonl \
  --contract-type ollama_native
```

### Typical commands — weatherforecast (N tools)
```bash
# Generate text_tool_call data
DEEPSEEK_API_KEY=... bash scripts_training/generate/weatherforecast/run_generate.sh

# Generate ollama_native data (full)
DEEPSEEK_API_KEY=... bash scripts_training/generate/weatherforecast/run_generate_ollama_native.sh

# Top-up with Gemini
EXAMPLE_GEN_PROVIDER=gemini GEMINI_API_KEY=... TOTAL=600 \
  bash scripts_training/generate/weatherforecast/run_generate_ollama_native_incremental.sh

# Repair existing JSONL
scripts_training/.venv/bin/python \
  scripts_training/generate/py/generate_train_jsonl_gemini_incremental.py \
  --repair-only \
  --prompt scripts_training/servers/weatherforecast/datasets/ollama_native/generated_train_prompt.md \
  --out scripts_training/servers/weatherforecast/datasets/ollama_native/train.jsonl \
  --tools scripts_training/weatherforecast/weather_tools.jsonl \
  --contract-type ollama_native
```

### Important: domain-aware data augmentation
The `prepare_training_lines` function in [`common/py/dataset/training_data_augment.py`](scripts_training/common/py/dataset/training_data_augment.py) is **domain-aware** — it inspects the provided `tools_schema` to determine which domain (weather, webcrawl, or unknown) the pipeline is running for, and injects appropriate quality gate exemplars and tool result stubs accordingly:

- **Weather domain** (`weathersensorsmcp` / `weatherforecast`): injects weather exemplars (`get_devices_by_name`, `get_csv_measurement_data`, `get_weather_forecast`, `get_server_datetime`) and provides result stubs for all weather tools
- **Webcrawl domain**: injects webcrawl exemplars (`search_indexed_websites`, `list_indexed_pages`, `index_websites`, `get_indexed_page` with follow-up) and provides result stubs for webcrawl tools
- **Unknown domain**: returns empty exemplar list to avoid injecting domain-inappropriate tool calls

This is automatically handled when generation is triggered via `run_generate_contract.sh` which passes `--tools` to the generator, which in turn passes `tools_schema` to `prepare_training_lines()`.

### Important: follow-up rows and the validator
`synthesize_followup_rows` creates follow-up conversation rows where the final assistant turn is a plain text answer (no `tool_calls`). The `ollama_native` validator rejects these because it requires all assistant messages in the JSONL to have `tool_calls`. When the `--repair-only` path is used, skip `prepare_training_lines` and normalize directly — or run the manual inline normalization script documented in session notes.

---

## Training Pipeline (`train_mcp.sh`)

```bash
# Full pipeline — weathersensorsmcp (default scope)
bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b

# Full pipeline — webcrawl
bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b --server-scope webcrawl

# Full pipeline — weatherforecast
bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b --server-scope weatherforecast

# Individual stages (any scope)
bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b --only-train
bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b --only-ollama
bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b --only-quality-gate
```

The script:
1. Trains a LoRA adapter with MLX-LM on `train_split.jsonl` / `valid_split.jsonl`
2. Fuses adapter into full weights
3. Converts to GGUF (Q5_K_M)
4. Registers in Ollama with a Modelfile
5. Runs the quality gate (`quality_gate_core.py`)

For `ollama_native` contracts, the Modelfile TEMPLATE is overridden with a tools-aware ChatML Go template that includes `{{ .Tools }}`, `<tool_call>` XML rendering, and `.ToolCalls` response output. Without this, Ollama returns HTTP 400 "model does not support tools".

---

## Colab Notebooks

Notebooks in `notebooks/ollama_native/` and `notebooks/text_tool_call/` are Drive-only — they do **not** clone the repo. All data is read from Google Drive:

```
MyDrive/Tealkit/training/<SERVER_SCOPE>/mcp_out/train_split.jsonl
MyDrive/Tealkit/training/<SERVER_SCOPE>/mcp_out/valid_split.jsonl
```

Available notebooks per scope:

| Notebook | Scope | Contract |
|---|---|---|
| `weathersensorsmcp_qwen_train.ipynb` | weathersensorsmcp | text_tool_call |
| `weathersensorsmcp_ministral_train.ipynb` | weathersensorsmcp | text_tool_call |
| `weatherforecast_qwen_train.ipynb` | weatherforecast | text_tool_call |
| `webcrawl_qwen_train.ipynb` | webcrawl | text_tool_call |
| `ollama_native/weathersensorsmcp_qwen_train.ipynb` | weathersensorsmcp | ollama_native |
| `ollama_native/weathersensorsmcp_ministral_train.ipynb` | weathersensorsmcp | ollama_native |
| `ollama_native/weatherforecast_qwen_train.ipynb` | weatherforecast | ollama_native |
| `ollama_native/webcrawl_qwen_train.ipynb` | webcrawl | ollama_native |

Upload split files to Drive before running a Colab notebook. The notebooks use Unsloth + TRL SFTTrainer and upload the final GGUF to HuggingFace.

---

## Venv

The `.venv` embeds its creation path in `bin/` shebang lines. After moving the project folder, recreate it:

```bash
bash scripts_training/bootstrap_venv_mac.sh
```

Uses `uv` with arm64 Python 3.11. Installs `mlx-lm` and `huggingface_hub`.

---

## Scope and Constraints

- Keep scripts simple and procedural; prefer Python + shell wrappers.
- Do not include local CUDA training orchestration — that runs in Google Colab.
- Local scripts focus on: dataset generation, validation, MLX-LM local training, GGUF export, Ollama registration, quality gate.
- Generated output artifacts (`mcp_out/`, `datasets/*/train*.jsonl`, `outputs/`) are transient and should not be committed.
- Five server scopes exist, grouped by category: generic MCP (`filesystem`, `git`), TealKit inbuilt (`webcrawl`, `weatherforecast`), and external proprietary tested with TealKit (`weathersensorsmcp`). Each has its own tool schema and pipeline. The `run_generate_contract.sh` dispatching script reads `SERVER_SCOPE` and `CONTRACT_TYPE` environment variables to select the correct config.
