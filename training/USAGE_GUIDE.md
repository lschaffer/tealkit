# scripts_training Usage Guide

This guide covers the current recommended execution order for the refactored training pipeline.

The supported server scopes in the current workflow are:
- `filesystem` — Generic MCP: file system read/write/edit operations — free, usable with any agentic app from OpenClaw to Claude Desktop
- `git` — Generic MCP: git repository management — free, usable with any agentic app from OpenClaw to Claude Desktop
- `webcrawl` — TealKit inbuilt: Web Crawl MCP (6 tools: website indexing, reindexing, search, page listing)
- `weatherforecast` — TealKit inbuilt: Weather Forecast MCP (4 tools: current weather, hourly/daily forecast, city geocoding)
- `weathersensorsmcp` — External (proprietary) MCP server tested with TealKit (~15 tools: station lookup, measurements, forecasts, exports)

The supported presets in the current workflow are:
- `qwen2_5_3b` for local Mac / Apple Silicon training
- `qwen2_5_1_5b` for local Mac / Apple Silicon training (lightweight, smaller tool sets)
- `qwen3_4b` for Colab / CUDA training
- `ministral` (Ministral 3B) for Colab / CUDA training
- `llama3_2_3b` (Llama 3.2 3B) for Unsloth / Unsloth Studio training

The supported contracts in the current workflow are:
- `text_tool_call` for the existing embedded / llama.cpp-compatible tool-call format
- `ollama_native` as the native-Ollama path (which has a specialized quality gate checker)

## What This Folder Is For

Use the scripts in this folder to:
- generate synthetic MCP tool-calling datasets
- validate and split the training data
- train a small local model with LoRA
- fuse adapters and export GGUF
- register the result in Ollama
- run a quality gate before publishing or app integration

## Recommended First Run: Mac / Qwen2.5-3B

For the first local run on macOS, use the `text_tool_call` contract with the `qwen2_5_3b` preset.

1. Bootstrap the Python environment.

```bash
bash scripts_training/bootstrap_venv_mac.sh
source scripts_training/.venv/bin/activate
```

2. Export your DeepSeek key for dataset generation.

```bash
export DEEPSEEK_API_KEY="your_key_here"
```

If you want to keep using Gemini instead, set `EXAMPLE_GEN_PROVIDER=gemini` and export `GEMINI_API_KEY` before running the same generation scripts.

3. Generate the training dataset.

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate.sh
```

Use the incremental generator instead only when you want a larger or more coverage-focused dataset:

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```

4. Run the shared trainer end to end.

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_3b
```

That command is the main local pipeline. It handles LoRA training, fuse, GGUF export, Ollama registration, and the local quality gate unless you explicitly skip stages.

5. If training already finished and you only need the downstream stages again, rerun the same pipeline without retraining.

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_3b \
  --skip-train
```

6. If you only want to rerun the local quality gate against the registered model:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_3b \
  --only-quality-gate
```

## Weather Forecast MCP (weatherforecast)

This scope covers a lightweight 4-tool set for weather data retrieval. Recommended preset: `qwen2_5_1_5b`.

### Generate the dataset (text_tool_call)

```bash
bash scripts_training/generate/weatherforecast/run_generate.sh
```

Or incremental:

```bash
bash scripts_training/generate/weatherforecast/run_generate_incremental.sh
```

### Generate the dataset (ollama_native)

```bash
bash scripts_training/generate/weatherforecast/run_generate_ollama_native.sh
```

Or incremental:

```bash
bash scripts_training/generate/weatherforecast/run_generate_ollama_native_incremental.sh
```

### Train

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_1_5b
```

For the native contract:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_1_5b
```

### Custom context window

```bash
TRAIN_MAX_SEQ_LENGTH=16384 OLLAMA_NUM_CTX=16384 \
  bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_1_5b
```

## Web Crawl MCP (webcrawl)

This scope covers a 6-tool set for website indexing and search. Recommended preset: `qwen2_5_1_5b`.

### Generate the dataset (text_tool_call)

```bash
bash scripts_training/generate/webcrawl/run_generate.sh
```

Or incremental:

```bash
bash scripts_training/generate/webcrawl/run_generate_incremental.sh
```

### Generate the dataset (ollama_native)

```bash
bash scripts_training/generate/webcrawl/run_generate_ollama_native.sh
```

Or incremental:

```bash
bash scripts_training/generate/webcrawl/run_generate_ollama_native_incremental.sh
```

### Train

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_1_5b
```

For the native contract:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_1_5b
```

## Example: Ollama Native Scaffold Path

Use this path only when you want to exercise the new native-contract scaffolding.

1. Generate a native-contract dataset scaffold:

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_ollama_native.sh
```

Or the incremental native scaffold:

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_ollama_native_incremental.sh
```

If generating the native dataset specifically for the Ministral training path (which uses the separate `mcp_out_ministral` output folder):

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_ministral_ollama_native.sh
# or incremental:
bash scripts_training/generate/weathersensorsmcp/run_generate_ministral_ollama_native_incremental.sh
```

2. Run the shared trainer with the native contract:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_3b
```

3. Re-run downstream native stages without retraining:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_3b \
  --skip-train
```

Important note: `ollama_native` now includes a native quality gate that checks Ollama `tool_calls` behavior directly. It is still newer than the stable text path, but generation, notebook wiring, and evaluator specialization are now aligned to the native contract.

## Suggested Script Order on Mac

Use this exact order for the first Qwen2.5 run:

1. `bash scripts_training/bootstrap_venv_mac.sh`
2. `source scripts_training/.venv/bin/activate`
3. `export DEEPSEEK_API_KEY="..."`
4. `bash scripts_training/generate/weathersensorsmcp/run_generate.sh`
5. `bash scripts_training/train/train_mcp.sh --contract-type text_tool_call --preset qwen2_5_3b`

Use this order for a rerun after the dataset already exists:

1. `source scripts_training/.venv/bin/activate`
2. `bash scripts_training/train/train_mcp.sh --contract-type text_tool_call --preset qwen2_5_3b --skip-train`

Use this order for the weatherforecast scope (lightweight 4-tool set, 1.5B preset):

1. `source scripts_training/.venv/bin/activate`
2. `export DEEPSEEK_API_KEY="..."`
3. `bash scripts_training/generate/weatherforecast/run_generate.sh`
4. `bash scripts_training/train/train_mcp.sh --contract-type text_tool_call --preset qwen2_5_1_5b`

Use this order for the webcrawl scope (6-tool set, 1.5B preset):

1. `source scripts_training/.venv/bin/activate`
2. `export DEEPSEEK_API_KEY="..."`
3. `bash scripts_training/generate/webcrawl/run_generate.sh`
4. `bash scripts_training/train/train_mcp.sh --contract-type text_tool_call --preset qwen2_5_1_5b`

Native scaffold example order:

1. `source scripts_training/.venv/bin/activate`
2. `export DEEPSEEK_API_KEY="..."`
3. `bash scripts_training/generate/weathersensorsmcp/run_generate_ollama_native.sh`
4. `bash scripts_training/train/train_mcp.sh --contract-type ollama_native --preset qwen2_5_3b`

## Uploading Trained Models to HuggingFace

After training, upload the trained GGUF + Modelfile to HuggingFace so others can download and use the model.

### Upload via `train_mcp.sh` (Mac/MLX path)

Upload as part of the full pipeline:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_3b \
  --upload-hf \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp
```

Upload-only mode (if GGUF already exists):

```bash
bash scripts_training/train/train_mcp.sh \
  --preset qwen2_5_3b \
  --only-hf-upload \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp
```

For native Ollama contract (adds `-ollama` suffix):

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_3b \
  --upload-hf \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp-ollama
```

Private repo:

```bash
bash scripts_training/train/train_mcp.sh \
  --preset qwen2_5_3b \
  --upload-hf \
  --hf-repo your-user/private-model \
  --hf-private
```

### Upload via Colab notebook

The last cell of each notebook in `scripts_training/notebooks/` handles HF upload directly via `huggingface_hub`. After training and GGUF export, the notebook pushes GGUF + Modelfile to the configured HF repo.

### Generic MCP server presets (filesystem & git)

These presets are for anyone using the popular [`filesystem`](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) and [`git`](https://github.com/modelcontextprotocol/servers/tree/main/src/git) MCP servers — free, usable with any agentic app from OpenClaw to Claude Desktop:

```bash
# Upload filesystem GGUF (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope filesystem \
  --preset qwen2_5_1_5b \
  --only-hf-upload \
  --hf-repo your-user/qwen25-1p5b-filesystem

# Upload git GGUF (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope git \
  --preset qwen2_5_1_5b \
  --only-hf-upload \
  --hf-repo your-user/qwen25-1p5b-git
```

### TealKit inbuilt MCP tools (webcrawl & weatherforecast)

These presets are for the built-in TealKit MCP servers:

```bash
# Upload weatherforecast (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope weatherforecast \
  --preset qwen2_5_1_5b \
  --only-hf-upload \
  --hf-repo your-user/qwen25-1p5b-weatherforecast

# Upload webcrawl (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope webcrawl \
  --preset qwen2_5_1_5b \
  --only-hf-upload \
  --hf-repo your-user/qwen25-1p5b-webcrawl
```

### External MCP server tested with TealKit (weathersensorsmcp)

These presets are for the external proprietary weather sensor MCP server tested with TealKit:

```bash
# Upload weathersensorsmcp (3B)
bash scripts_training/train/train_mcp.sh \
  --server-scope weathersensorsmcp \
  --preset qwen2_5_3b \
  --only-hf-upload \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp
```

### Example repos per scope

| Scope | Type | Example HF repo |
|---|---|---|
| filesystem (1.5B) | Generic MCP — free, usable with any agentic app | `your-user/qwen25-1p5b-filesystem` |
| git (1.5B) | Generic MCP — free, usable with any agentic app | `your-user/qwen25-1p5b-git` |
| webcrawl (1.5B) | TealKit inbuilt | `lschaffer/qwen25-1p5b-webcrawl` |
| weatherforecast (1.5B) | TealKit inbuilt | `lschaffer/qwen25-1p5b-weatherforecast` |
| weathersensorsmcp (3B) | External (proprietary) tested with TealKit | `lschaffer/qwen2.5-3b-weathersensorsmcp` |
| weathersensorsmcp (Ministral 3B) | External (proprietary) tested with TealKit | `lschaffer/ministral-3b-weathersensorsmcp` |

---

## Updating / Forcing Fresh Model Downloads
If you retrain a model and push updated weights to HuggingFace, the local download script will skip downloading the GGUF if it finds it already cached inside `hf_models/`. To force a clean update download, delete the old cached GGUF file locally first:

```bash
# Remove cached old GGUF weights
rm -f ./hf_models/qwen2.5-3b-weathersensorsmcp-ollama/qwen2.5-3b-weathersensorsmcp-ollama-q5_k_m.gguf

# Fetch updated weights from HuggingFace and re-register
./scripts_training/download-hf-model.sh lschaffer/qwen2.5-3b-weathersensorsmcp-ollama
```

## Colab / Notebook Status

The notebook migration is documented separately in [COLAB_NOTEBOOK_CHANGES.md](COLAB_NOTEBOOK_CHANGES.md).

Current notebook families in the repo are:
- `scripts_training/notebooks/text_tool_call/weathersensorsmcp_qwen_train.ipynb`
- `scripts_training/notebooks/text_tool_call/weathersensorsmcp_ministral_train.ipynb`
- `scripts_training/notebooks/text_tool_call/weatherforecast_qwen_train.ipynb`
- `scripts_training/notebooks/text_tool_call/webcrawl_qwen_train.ipynb`
- `scripts_training/notebooks/ollama_native/weathersensorsmcp_qwen_train.ipynb`
- `scripts_training/notebooks/ollama_native/weathersensorsmcp_ministral_train.ipynb`
- `scripts_training/notebooks/ollama_native/weatherforecast_qwen_train.ipynb`
- `scripts_training/notebooks/ollama_native/webcrawl_qwen_train.ipynb`

The text notebooks are the stable legacy-contract Colabs. The native notebooks are now runnable bootstrap notebooks for the `ollama_native` path. The weatherforecast and webcrawl notebooks target `unsloth/Qwen2.5-1.5B-Instruct` and follow the same Colab flow as the weathersensorsmcp notebooks.

## Main Files You Will Use

- `bootstrap_venv_mac.sh` - local Python and MLX setup
- `generate/weathersensorsmcp/run_generate.sh` - text-contract dataset generation (weathersensorsmcp)
- `generate/weathersensorsmcp/run_generate_incremental.sh` - incremental text-contract generation (weathersensorsmcp)
- `generate/weathersensorsmcp/run_generate_ollama_native.sh` - scaffolded native-contract generation (weathersensorsmcp)
- `generate/weatherforecast/run_generate.sh` - text-contract dataset generation (weatherforecast)
- `generate/weatherforecast/run_generate_incremental.sh` - incremental text-contract generation (weatherforecast)
- `generate/weatherforecast/run_generate_ollama_native.sh` - scaffolded native-contract generation (weatherforecast)
- `generate/weatherforecast/run_generate_ollama_native_incremental.sh` - incremental native-contract generation (weatherforecast)
- `generate/webcrawl/run_generate.sh` - text-contract dataset generation (webcrawl)
- `generate/webcrawl/run_generate_incremental.sh` - incremental text-contract generation (webcrawl)
- `generate/webcrawl/run_generate_ollama_native.sh` - scaffolded native-contract generation (webcrawl)
- `generate/webcrawl/run_generate_ollama_native_incremental.sh` - incremental native-contract generation (webcrawl)
- `train/train_mcp.sh` - main end-to-end local training/export pipeline
- `common/py/quality_gate/quality_gate_core.py` - shared quality-gate implementation
- `servers/weathersensorsmcp/configs/text_tool_call/config.json` - text-contract config (weathersensorsmcp)
- `servers/weathersensorsmcp/configs/ollama_native/config.json` - native-contract config (weathersensorsmcp)
- `servers/weatherforecast/configs/text_tool_call/config.json` - text-contract config (weatherforecast)
- `servers/weatherforecast/configs/ollama_native/config.json` - native-contract config (weatherforecast)
- `servers/webcrawl/configs/text_tool_call/config.json` - text-contract config (webcrawl)
- `servers/webcrawl/configs/ollama_native/config.json` - native-contract config (webcrawl)

## Common Outputs

- `scripts_training/weathersensorsmcp/mcp_out/` - generated text-contract dataset files (weathersensorsmcp)
- `scripts_training/weathersensorsmcp/mcp_out_ministral/` - legacy separate output bucket for Ministral wrappers
- `scripts_training/servers/weatherforecast/datasets/text_tool_call/` - generated text-contract dataset files (weatherforecast)
- `scripts_training/servers/weatherforecast/datasets/ollama_native/` - generated native-contract dataset files (weatherforecast)
- `scripts_training/servers/webcrawl/datasets/text_tool_call/` - generated text-contract dataset files (webcrawl)
- `scripts_training/servers/webcrawl/datasets/ollama_native/` - generated native-contract dataset files (webcrawl)
- `mcp_adapters_*` - LoRA adapter outputs
- `mcp_fused_model_*` - fused model checkpoints
- `*.gguf` - final runtime artifacts

## Preset Notes

- `qwen2_5_3b` is the current Mac / Apple Silicon default for weathersensorsmcp.
- `qwen2_5_1_5b` is the recommended preset for lightweight scopes (weatherforecast, webcrawl) with smaller tool sets.
- `qwen3_4b` remains the main Colab preset.
- `text_tool_call` is the stable path to use first.
- `ollama_native` is scaffolded, but the notebook and evaluator path still need deeper specialization before it becomes the default training route.

## Legacy Helpers

Some helper scripts remain in the folder for compatibility or recovery workflows. They are not part of the default path unless a task explicitly asks for them.
