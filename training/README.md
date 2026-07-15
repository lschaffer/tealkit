# MCP Tool-Calling Training Guide

This guide explains the training phases for adapting a small local model (SLM) to reliable MCP tool calling.

It includes:
- Generic concepts (GGUF, Q4/Q5, Instruct, LoRA, teacher-to-student workflow)
- The concrete scripts implemented in this folder
- Practical command examples for dataset generation, training flow, GGUF export, and upload

The workflow is intentionally narrow:

1. Generate a supervised dataset from MCP tool schemas with a strong teacher model, now defaulting to DeepSeek V4 Pro.
2. Fine-tune a small local model with LoRA.
3. Fuse adapters, export GGUF, register in Ollama, and run a quality gate.

The recommended combinations in this repo are:

- Mac / Apple Silicon: `qwen2_5_3b` (scripts) or any model via Unsloth Studio
- Colab: `ministral_3b` (recommended) via `text_tool_call/weathersensorsmcp_ministral_train.ipynb`

## Current Recommended Entry Order

For the first local run on macOS, start with the stable text contract and the Qwen2.5 preset:

1. `bash scripts_training/bootstrap_venv_mac.sh`
2. `source scripts_training/.venv/bin/activate`
3. `export DEEPSEEK_API_KEY="..."`
4. `bash scripts_training/generate/weathersensorsmcp/run_generate.sh`
5. `bash scripts_training/train/train_mcp.sh --contract-type text_tool_call --preset qwen2_5_3b`

If the dataset already exists and you only want to rerun downstream stages, use:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_3b \
  --skip-train
```

If you want to exercise the scaffolded native Ollama contract path, use:

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_ollama_native.sh

bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_3b
```

And to rerun the native path without retraining:

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_3b \
  --skip-train
```

This `ollama_native` path now has a native quality gate that probes Ollama `tool_calls` behavior directly. It is still newer than the `text_tool_call` path, but generation, trainer wiring, notebooks, and evaluator specialization are now aligned to the native contract.

The more detailed run order is documented in [USAGE_GUIDE.md](USAGE_GUIDE.md).

The Colab notebook migration notes are documented in [COLAB_NOTEBOOK_CHANGES.md](COLAB_NOTEBOOK_CHANGES.md).

## Is It Worth Training?

**Short answer: yes for small models, no for large ones.**

| Scenario | Worth fine-tuning? | Why |
|---|---|---|
| 1B–1.5B mini models on mobile | **Yes, with limits** | Good only for small, focused tool sets (≤10 tools). With more than 10 tools the model cannot reliably hold the full schema in working context even after fine-tuning — tool selection and parameter accuracy degrade noticeably. Use a 3B model if your schema is larger. |
| 2B–3B on mobile (Android / iOS) | **Yes** | The practical mobile sweet spot. Fine-tuning makes tool-call reliability jump noticeably. The GGUF fits in 2–4 GB and inference is fast on device. Can handle schemas of 15–25 tools reliably after training. |
| 7B–9B on Mac Mini M4 Pro | **Yes** | Plenty of headroom for LoRA training in MLX. A fine-tuned 7–9B can match a generic 14B on the specific schema while running twice as fast. |
| >14B (any hardware) | **Probably not** | A model this size with a well-written system prompt that includes tool skill examples (few-shot tool calls) usually performs well enough. The training cost rarely pays off unless the schema is very large or unusual. |

The practical rule: **if the model can't reliably call your tools after 2–3 prompt iterations, fine-tune it. If a 14B+ model calls the tools correctly with a good system prompt, skip training.**

### Fine-Tuning Worth It?

**Yes, if:**
- Your tool schemas are complex or domain-specific (base models hallucinate wrong tool names or arguments)
- If your MCP server has at most 20 tools.
- You need consistent output format (bare JSON, `tool_call:` prefix, etc.)
- You are targeting 1B–7B models, which have weak out-of-the-box tool-call fidelity

**Probably not, if:**
- You are using a 13B+ instruct model (already has strong tool-call fidelity with a good system prompt and a few few-shot examples)
- You only have a handful of tools — a well-crafted system prompt may be sufficient

**Hard limits by model size:**
- **1B–1.5B** — max ~10 tools. Beyond that, even fine-tuned models struggle to select the right tool and fill parameters correctly. Suitable for simple, tightly scoped assistants.
- **2B–3B** — practical ceiling of ~20–25 tools at acceptable accuracy. This is the recommended mobile target for real MCP integrations.
- **7B+** — can handle 40+ tools reliably; schema complexity is rarely the limiting factor at this size.

## Core Concepts

### Teacher-to-Student Fine-Tuning

You use a stronger API model such as DeepSeek V4 Pro to synthesize `tool_call` and `no_tool` examples from your MCP tool schema. A smaller local model then learns to reproduce those structured tool calls through LoRA fine-tuning.

By default the generator now uses `EXAMPLE_GEN_PROVIDER=deepseek` and `EXAMPLE_GEN_MODEL=deepseek-v4-pro`. You can still switch back to Gemini with `EXAMPLE_GEN_PROVIDER=gemini` and `GEMINI_API_KEY=...`, or use another OpenAI-compatible endpoint with `EXAMPLE_GEN_PROVIDER=openai_compatible`, `EXAMPLE_GEN_API_KEY`, and `EXAMPLE_GEN_BASE_URL`.

For this kind of task, even a 3B model can become useful when the dataset is clean and the output contract is strict.

### GGUF

GGUF is the runtime format used by `llama.cpp`-style runtimes such as Ollama and LM Studio. It packages model weights and metadata in a runtime-friendly binary format. After training, the repo fuses the adapters into a full model checkpoint and converts that checkpoint into GGUF.

### Instruct Models

An Instruct model is a base model that has been further tuned to follow user instructions and chat format. For tool calling, always start from an Instruct checkpoint — base (pretrain-only) checkpoints do not understand the instruction-response contract at all.

### What Is a Weight?

A weight is a learned numeric value on a connection or projection inside the model. During training, the model continuously adjusts these values to reduce prediction error — this process of adjustment is what "learning" means in practice.

Weights collectively encode everything the model has learned: grammar, facts, reasoning patterns, and — after fine-tuning — how to call your tools correctly.

For a deeper understanding of how weights fit into the broader Transformer architecture (attention heads, layers, feed-forward blocks), see this excellent publication:
[How Transformers Architecture Powers Modern AI — ByteByteGo (Alex Xu)](https://blog.bytebytego.com/p/how-transformers-architecture-powers)

### What Is an Adapter?

An adapter is a small set of additional trainable weights attached to the base model. During fine-tuning, only these adapter weights are updated — the original base model is left unchanged.

Why this matters:
- Training is cheaper (less memory and compute)
- You can swap task-specific adapters in and out (for example, one adapter for MCP tool calling, another for summarisation)
- The adapter checkpoint is small and easy to share or version independently

In LoRA workflows, "the adapter" means the LoRA checkpoint directory produced after training.

### LoRA and Adapter Rank

LoRA fine-tunes small low-rank adapter matrices instead of rewriting the full base model. That keeps training feasible on Apple Silicon and makes it easy to fuse the adapter into a new checkpoint after training.

The rank (`r`) controls the size of the adapter and its learning capacity:

| Rank | VRAM | Capacity | Typical use |
|---|---|---|---|
| `r=8` | lowest | compact | Qwen2.5 1.5B / 3B |
| `r=16` | moderate | balanced | Phi-4-mini, Qwen3-4B |
| `r=32` | higher | more capacity | larger datasets / more complex schemas |

Practical starting point: use `r=16`. Increase only if validation quality plateaus and your memory budget allows. Higher rank also increases overfitting risk on small datasets.

### Quantization: Q4 vs Q5

| Format | RAM | Speed | Tool-call reliability |
|---|---|---|---|
| Q4_K_M | smallest | fastest | good |
| Q5_K_M | +15–20% | slightly slower | better |

Q5 is the preferred default for tool-calling if latency is still acceptable.

## Recommended Model Sizes by Hardware

| Target | RAM | Recommended size | GGUF format | Notes |
|---|---|---|---|---|
| Mobile (Android / iOS) | 8–12 GB | 1B–3B | Q4_K_M or Q5_K_M | >3B at Q5 usually gets slow |
| Mac Mini M4 Pro | 24 GB unified | 3B–4B train, up to 14B infer | Q5_K_M | MLX training <=4B is the practical path |
| Windows / Linux with NVIDIA >=16 GB | 24–32 GB | 7B–14B | Q5_K_M | GPU required for good speed |
| Windows / Linux CPU-only | 24–32 GB | 3B | Q4_K_M | >3B CPU-only is usually not worth it |
| Colab Pro H100 | 80 GB | 3B–4B+ | Q5_K_M | best quality path in this repo is Qwen3-4B notebook |

**Key rules:**
- Leave ~4 GB headroom for the OS and runtime overhead (Ollama, KV cache, context window).
- On Apple Silicon, unified memory means the GPU and CPU share the same pool — a 24 GB Mac Mini M4 Pro can run 14B models at reduced context and comfortably train 3B–4B models.
- On mobile, anything above 3B at Q5 will have latency ≥3 s/token, making interactive tool calling feel sluggish.
- On Windows and Linux, a **dedicated GPU with ≥16 GB VRAM is effectively required** for models above 3B. CPU-only inference of a 7B+ model can take 30–60 s/token — unusable for interactive use.

**Context window and model size trade-off:**
Larger models consume more memory *per token*, which leaves less room for the KV cache that backs the context window. In practice:
- A **3B model at Q5** on 8 GB can hold a 4K–8K context comfortably.
- A **7B model at Q5** on 16 GB is typically limited to 4K context before OOM risk.
- A **14B model at Q5** on 24 GB unified (Mac Mini M4 Pro) can manage 2K–4K context reliably; 8K is possible but tight.

If your MCP prompts are long (large tool schemas + conversation history), **prefer a smaller model with a larger context window** over a larger model squeezed into the same RAM. Ollama's `num_ctx` parameter controls this — set it explicitly rather than relying on the default.

## Current Preset Recommendation

- `qwen3_4b` is the **default Colab path**. Trained via `text_tool_call/weathersensorsmcp_qwen_train.ipynb` (Unsloth, ChatML template, thinking mode suppressed). Has a full video walkthrough.
- `ministral_3b` is the **alternative Colab path** for the same weathersensorsmcp dataset, trained via `text_tool_call/weathersensorsmcp_ministral_train.ipynb`. Ministral 3B (Dec 2025) is explicitly designed for edge function-calling with no thinking mode — simpler setup, cleaner stop token handling.
- `qwen2_5_3b` is the **Mac / Apple Silicon scripts default**. Automatically sets `TRAIN_ITERS=500` and `TRAIN_LR=5e-5` when used with the `weathersensorsmcp` scope.
- `llama3_2_3b` is the **Unsloth Studio example** on Mac. Exports cleanly to GGUF via the Studio GUI.
- `qwen2_5_1_5b` is available for experiments and lighter mobile targets, but expect weaker tool-call fidelity than 3B.

## Presets in This Pipeline

| Preset | Mac/MLX model | Colab/CUDA model | Size |
|---|---|---|---|
| `qwen3_4b` | — | `unsloth/Qwen3-4B` | ~4B |
| `ministral_3b` | — | `unsloth/Ministral-3-3B-Instruct-2512` | ~3B |
| `qwen2_5_3b` | `mlx-community/Qwen2.5-3B-Instruct-4bit` | — | ~3B |
| `llama3_2_3b` | `mlx-community/Llama-3.2-3B-Instruct-4bit` (Studio) | — | ~3B |
| `qwen2_5_1_5b` | `mlx-community/Qwen2.5-1.5B-Instruct-4bit` | — | ~1.5B |

### Training Presets (Server Scopes)

The following server scopes have been created with their own training data generation pipeline, prompt contracts, and system prompts:

| Server Scope | Contract Types | Current Context Window | Category | Description |
|---|---|---|---|---|
| `filesystem` | `text_tool_call`, `ollama_native` | **16K (16384)** | Generic MCP | File system read/write/edit operations — free, usable with any agentic app from OpenClaw to Claude Desktop |
| `git` | `text_tool_call`, `ollama_native` | **16K (16384)** | Generic MCP | Git repository management — free, usable with any agentic app from OpenClaw to Claude Desktop |
| `ssh` | `text_tool_call`, `ollama_native` | **16K (16384)** | Generic MCP | SSH/SFTP remote server management — list/read/upload/download files, run commands. 9 tools, ideal for 1.5B–3B models |
| `webcrawl` | `text_tool_call`, `ollama_native` | **16K (16384)** | TealKit inbuilt | Web crawling and scraping — built-in MCP tool of TealKit |
| `weatherforecast` | `text_tool_call`, `ollama_native` | **16K (16384)** | TealKit inbuilt | Weather forecast retrieval — built-in MCP tool of TealKit |
| `weathersensorsmcp` | `text_tool_call`, `ollama_native` | **16K (16384)** | External (proprietary) | Weather sensor tool calling — external proprietary MCP server tested with TealKit |

All scopes now use a **16K (16384) context window** to allow enough space for bigger prompts when using small models. Note that the usable context window also depends on hardware capabilities (RAM/VRAM) and the model architecture — smaller models may not effectively utilise the full 16K window on all devices.

### Configuring the Context Window

The context window is controlled by two related settings that must be kept in sync:

| Setting | Purpose | Where to set |
|---|---|---|
| `MAX_SEQ_LENGTH` | Training sequence length (Unsloth/Colab) | Notebook Cell 2 |
| `TRAIN_MAX_SEQ_LENGTH` | Training sequence length (Mac `train_mcp.sh`) | Env variable or script default |
| `OLLAMA_NUM_CTX` | Ollama inference context window | Env variable or script default |

**In Colab notebooks**, set `MAX_SEQ_LENGTH` in Cell 2. Supported values for Qwen2.5-1.5B:

| Value | Memory | Recommended GPU |
|---|---|---|
| 8192 (8K) | Any GPU | T4/L4/H100 |
| **16384 (16K)** | Comfortable | **L4/H100 (default for new presets)** |
| 32768 (32K) | High | H100, reduced batch size |
| 65536 (64K) | Very high | H100 with YaRN |

The Colab notebook generates a Modelfile with `PARAMETER num_ctx {MAX_SEQ_LENGTH}`, so the inference context window matches the training window automatically.

**On Mac (`train_mcp.sh`)**, set via environment variables:

```bash
# Override both at runtime:
TRAIN_MAX_SEQ_LENGTH=16384 OLLAMA_NUM_CTX=16384 ./train_mcp.sh

# The script also has scope-aware defaults (see train_mcp.sh line ~660):
#   filesystem|git (generic MCP)  → 16384
#   webcrawl|weatherforecast (TealKit inbuilt) → 16384
#   weathersensorsmcp (external proprietary) → 16384
#   any other scope     → 2048
```

The built-in defaults per scope (set in [`train_mcp.sh:659-680`](scripts_training/train/train_mcp.sh:659)):

```bash
case "$TRAIN_SCOPE" in
   filesystem|git)
       # Generic MCP tools — free, usable with any agentic app
       TRAIN_MAX_SEQ_LENGTH="16384"
       OLLAMA_NUM_CTX="16384"
       ;;
   webcrawl|weatherforecast)
       # Built-in TealKit MCP tools
       TRAIN_MAX_SEQ_LENGTH="16384"
       OLLAMA_NUM_CTX="16384"
       ;;
   weathersensorsmcp)
       # External proprietary MCP server tested with TealKit
       TRAIN_MAX_SEQ_LENGTH="16384"
       OLLAMA_NUM_CTX="16384"
       ;;
   *)
       TRAIN_MAX_SEQ_LENGTH="2048"
       OLLAMA_NUM_CTX="2048"
       ;;
esac
```

**To add a new scope or change the context window for an existing one**, modify the `case` statement at [`train_mcp.sh:659`](scripts_training/train/train_mcp.sh:659) (for the `qwen2_5_3b` preset) and update `MAX_SEQ_LENGTH` in the corresponding Colab notebook.

**In Ollama Modelfiles directly**, if you need to adjust a trained model's context window without retraining:

```bash
# Edit the Modelfile and change:
PARAMETER num_ctx 16384

# Then recreate:
ollama create my-model -f Modelfile
```

Or at inference time via the Ollama API:
```bash
curl http://localhost:11434/api/generate -d '{
 "model": "my-model",
 "prompt": "...",
 "options": { "num_ctx": 16384 }
}'
```

### There Is No Universal Training Solution

Fine-tuning is **not a generic, vendor-agnostic process**. Each model family has its own tokenizer format, chat template, and tool-call output convention:

- **Qwen (Alibaba)** — uses tiktoken-style BPE; outputs tool calls as JSON with a `tool_call:` prefix or as a raw JSON object. The training data format and system prompt must match Qwen's chat template exactly.
  Qwen 2.5 Instruct models have strong pre-trained tool-calling behaviour (outputting `{"tool_call": "..."}` dict
  wrappers). Fine-tuning to a different output format requires a learning rate of at least 1e-4; at the 5e-6
  global default the LoRA weight updates are too small to override the base model's pre-trained instincts and
  the model reverts to its native format at inference time regardless of training loss.
- **Qwen3** — same BPE tokenizer family as Qwen2.5. Uses `<|im_end|>` ChatML tokens natively. When trained with Unsloth using `chat_template='chatml'`, thinking mode is suppressed and the output format is identical to Qwen2.5 ChatML, making adapter and Modelfile configuration consistent across the Qwen family. However, residual thinking-mode tendencies at inference time can degrade exact-format tool-call reliability even after fine-tuning.
- **Mistral / Ministral (Mistral AI)** — uses the Mistral v3 tekken tokenizer with `[INST]...[/INST]` chat format. Has no thinking mode. The Unsloth `chat_template='mistral'` is used directly (no override needed). The Ollama Modelfile uses the standard Mistral `[INST]` template with `</s>` as the stop token. Tool calls use the same `tool_call: {...}` prefix format as the Qwen path — no pipeline changes required downstream.
- **Llama 3.2 (Meta)** — uses the Llama-3/3.2 Tiktoken tokenizer with `<|start_header_id|>...<|end_header_id|>` headers. It is highly sensitive to correct template endings. Fine-tunes beautifully via Unsloth Studio.

### Tool Calling Output Formats & Examples

Depending on the contract type used, the models generate different output structures:

#### A. Text Tool Call Contract (`text_tool_call`)
In the legacy `text_tool_call` format, the model outputs a plain text prefix followed by a JSON object. All model types (Qwen, Mistral, Llama) output this exact raw string format:

```text
tool_call: {"name": "get_devices_by_name", "arguments": {"dluName": "DLU-123", "detail": 1, "grpId": -1}}
```

#### B. Native Ollama Contract (`ollama_native`)
In the `ollama_native` format, the model outputs raw JSON conforming to Ollama's native tool-calling JSON wrapper schema. Note that the assistant output has *empty text* content, and is wrapped inside a `tool_calls` block:

* **Qwen2.5 / Qwen3 / Llama 3.2 Native Chat Response (via Ollama API):**
  ```json
  {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "function": {
          "name": "get_devices_by_name",
          "arguments": {
            "dluName": "DLU-123",
            "detail": 1,
            "grpId": -1
          }
        }
      }
    ]
  }
  ```

* **Ministral Native Response:**
  ```json
  {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "function": {
          "name": "get_devices_by_name",
          "arguments": {
            "dluName": "DLU-123",
            "detail": 1,
            "grpId": -1
          }
        }
      }
    ]
  }
  ```

If you switch presets, expect to debug the GGUF conversion, system prompt, and quality gate independently for each vendor. The scripts in this pipeline abstract many of these differences, but the underlying complexity is real.

## Example Use Cases

The scripts in this repo are demonstrated with three concrete server scopes, each with its own tool schema, system prompt, and generated dataset:

### Weather Sensors MCP (`weathersensorsmcp`)

The primary end-to-end scenario: fine-tuning a small model to call a remote MCP server (Weather Sensors MCP).
Exposes station lookup, live measurements, forecasts, and export tools (up to ~15 tools — well within the 3B sweet spot).
The model learns the full schema so it can drive the weather service reliably without a large system prompt.

Full pipeline: export tool definitions as JSONL → generate training data → train on Mac or Colab → export GGUF → upload to HF → use with Ollama.

### Weather Forecast MCP (`weatherforecast`)

A lightweight 4-tool set: `get_current_weather`, `get_hourly_forecast`, `get_daily_forecast`, `geocode_weather_city`.
Ideal for testing the pipeline with a narrow schema. Recommended preset: `qwen2_5_1_5b`.

### Web Crawl MCP (`webcrawl`)

A 6-tool set for website indexing and search: `index_websites`, `reindex_websites`, `purge_stale_index`, `list_indexed_pages`, `search_indexed_websites`, `get_indexed_page`.
Demonstrates the pipeline with a search-oriented tool set. Recommended preset: `qwen2_5_1_5b`.

### File System MCP (`filesystem`)

A Node.js MCP server for local filesystem access. Exposes 14 tools including reading (`read_text_file`, `read_multiple_files`), writing/modifying (`write_file`, `edit_file`), listing directory structures (`list_directory`, `directory_tree`), moving/searching/retrieving metadata, and listing allowed access directories. Recommended preset: `qwen2_5_1_5b`.

### Git MCP (`git`)

A Python MCP server for local Git repository management. Exposes 12 tools for checking status (`git_status`), viewing diffs (`git_diff_unstaged`, `git_diff_staged`, `git_diff`), committing changes (`git_commit`), staging/unstaging (`git_add`, `git_reset`), log/history (`git_log`), branch operations (`git_create_branch`, `git_checkout`, `git_branch`), and inspecting commits (`git_show`). Recommended preset: `qwen2_5_1_5b`.

The scripts accept any tool schema JSONL as input. Adapt the server folders to your own MCP server to apply the same pipeline to any tool set.

## Folder Layout

Main folders:

- `weathersensorsmcp/`: weather sensors example — tool schema, system prompt, and generated dataset.
- `servers/`: per-server scaffolding — configs, prompts, datasets, and outputs for each server scope.
  - `servers/weathersensorsmcp/`: Weather Sensors MCP configs, prompts, datasets, outputs.
  - `servers/weatherforecast/`: Weather Forecast MCP configs, prompts, datasets, outputs.
  - `servers/webcrawl/`: Web Crawl MCP configs, prompts, datasets, outputs.
  - `servers/filesystem/`: File System MCP configs, prompts, datasets, outputs.
  - `servers/git/`: Git MCP configs, prompts, datasets, outputs.
  - `servers/ssh/`: SSH/SFTP MCP configs, prompts, datasets, outputs.
- `contracts/`: prompt contract definitions and quality gate profiles per server per contract type.
- `generate/`: dataset generation scripts (generic launcher + per-server wrappers).
- `train/`: training pipeline scripts and helpers.
- `quality_gate/`: quality gate script and profile-specific launchers.
- `notebooks/`: Colab training notebooks per server and contract type.
- `ps1_files/`: PowerShell helpers.

Generated artifact folders:

- `*/mcp_out/`: generated training datasets and train/valid splits.
- `*/mcp_adapters_*`: LoRA adapter outputs.
- `*/mcp_fused_model_*`: fused model outputs and GGUF artifacts.
- `*/mcp_merged_model_*`: merged checkpoints used before GGUF conversion.

## Example Video Series

End-to-end walkthrough of the full training pipeline:

1. [Export MCP Tool Definitions from Tealkit as JSONL](https://youtu.be/-AViiOA-kg4)
2. [Generate a Training Dataset from the Definitions with Gemini 2.5 Pro](https://youtu.be/SAJzq2nH9i8)
3. [Train Qwen3-4B on the Dataset in Google Colab (H100)](https://youtu.be/jsiZAsctTyg)
4. [Train Qwen2.5-3B on Mac Mini M4 Pro](https://youtu.be/UXUwlceSftI)

## Mac Workflow

This is the main local workflow. There are two paths depending on your preference:

- **Terminal / scripts path** — full control, scriptable, integrates with the quality gate and HF upload helpers. Requires the MLX venv bootstrapped via `bootstrap_venv_mac.sh`.
- **Unsloth Studio path** — GUI-based, no terminal setup required, ideal for quick iteration. The dataset files are still generated locally via the scripts, then loaded into the Studio UI.

---

## Mac Workflow — Terminal / Scripts (Hard Work Path)

This is the original local workflow driven entirely from the terminal.

### 1. Bootstrap the environment

```bash
bash scripts_training/bootstrap_venv_mac.sh
source scripts_training/.venv/bin/activate
```

If needed, install `uv` first:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### 2. Generate the training dataset

Instead of writing training examples by hand, a large language model (DeepSeek V4 Pro or Gemini 2.5 Pro) is used to generate the dataset automatically.
The source prompt (`train_prompt.md`) contains the full instructions: which MCP tools to cover, the expected JSONL format, conversation style, and coverage targets.
The LLM reads the tool schema and produces realistic tool-calling dialogues at scale.

**Weather Sensors MCP files:**

- tool schema: `scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl`
- dataset prompt template: `scripts_training/weathersensorsmcp/train_prompt.md`
- runtime/training system prompt: `scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md`
- Ollama native system prompt: `scripts_training/servers/weathersensorsmcp/prompts/ollama_native_system_prompt.md`

Generate the weathersensorsmcp dataset:

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate.sh
```

Or use the incremental generator for larger schemas:

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```

**Weather Forecast MCP** (4-tool set: current weather, hourly/daily forecast, geocoding):

```bash
bash scripts_training/generate/weatherforecast/run_generate.sh
# or incremental:
bash scripts_training/generate/weatherforecast/run_generate_incremental.sh
```

**Web Crawl MCP** (6-tool set: indexing, search, page listing):

```bash
bash scripts_training/generate/webcrawl/run_generate.sh
# or incremental:
bash scripts_training/generate/webcrawl/run_generate_incremental.sh
```

**File System MCP** (14-tool set: filesystem operations):

```bash
bash scripts_training/generate/filesystem/run_generate.sh
# or incremental:
bash scripts_training/generate/filesystem/run_generate_incremental.sh
```

**Git MCP** (12-tool set: local git operations):

```bash
bash scripts_training/generate/git/run_generate.sh
# or incremental:
bash scripts_training/generate/git/run_generate_incremental.sh
```

**SSH MCP** (9-tool set: remote server management — list/read/upload/download files, run commands):

```bash
bash scripts_training/generate/ssh/run_generate.sh
# or incremental:
bash scripts_training/generate/ssh/run_generate_incremental.sh
```

Expected output for weathersensorsmcp:

- `scripts_training/weathersensorsmcp/mcp_out/train.jsonl`
- `scripts_training/weathersensorsmcp/mcp_out/train_split.jsonl`
- `scripts_training/weathersensorsmcp/mcp_out/valid_split.jsonl`

Expected output for weatherforecast/webcrawl/filesystem/git (text_tool_call):

- `scripts_training/servers/{scope}/datasets/text_tool_call/train.jsonl`
- `scripts_training/servers/{scope}/datasets/text_tool_call/train_split.jsonl`
- `scripts_training/servers/{scope}/datasets/text_tool_call/valid_split.jsonl`

Expected output for weatherforecast/webcrawl/filesystem/git (ollama_native):

- `scripts_training/servers/{scope}/datasets/ollama_native/train.jsonl`
- `scripts_training/servers/{scope}/datasets/ollama_native/train_split.jsonl`
- `scripts_training/servers/{scope}/datasets/ollama_native/valid_split.jsonl`

### Incremental generator behavior

The incremental generator uses semantic tool families instead of random tool slices.

For weathersensorsmcp the current families are:

- `station_lookup`
- `measurement_exports`
- `forecast_time`
- `visualization`

This means the early generation rounds deliberately focus on related tools together, and the top-up rounds target the lowest-coverage family instead of using a random mixed-schema batch.

Important knobs:

- `TOTAL`: final target line count
- `MIN_VALID`: minimum number of schema-valid lines required after validation
- `TOOLS_PER_CHUNK`: max tools in a semantic chunk before that family is split
- `EXAMPLES_PER_CHUNK`: requested examples per chunk
- `ATTEMPTS_PER_CHUNK`: retries for each chunk, keeping the best valid result

Recommended range for weather generation:

- `TOOLS_PER_CHUNK=4` or `5`
- `EXAMPLES_PER_CHUNK=80` to `120`
- `ATTEMPTS_PER_CHUNK=3` or `4`

Example:

```bash
TOTAL=1500 MIN_VALID=1250 TOOLS_PER_CHUNK=5 EXAMPLES_PER_CHUNK=90 ATTEMPTS_PER_CHUNK=4 \
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```

The incremental generator also prints a coverage summary at the end:

- count per tool
- count per family

Use that summary to confirm no tool is badly underrepresented before training.

### 3. Train locally

**Weather Sensors MCP (15 tools — recommended: qwen2_5_3b):**

```bash
MCP_SERVER=weathersensorsmcp \
TRAIN_SCOPE=weathersensorsmcp \
SYSTEM_PROMPT_FILE=scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b
```

**Weather Forecast MCP (4 tools — recommended: qwen2_5_1_5b):**

```bash
MCP_SERVER=weatherforecast \
TRAIN_SCOPE=weatherforecast \
SYSTEM_PROMPT_FILE=scripts_training/servers/weatherforecast/prompts/weatherforecast_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

**Web Crawl MCP (6 tools — recommended: qwen2_5_1_5b):**

```bash
MCP_SERVER=webcrawl \
TRAIN_SCOPE=webcrawl \
SYSTEM_PROMPT_FILE=scripts_training/servers/webcrawl/prompts/webcrawl_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

**File System MCP (14 tools — recommended: qwen2_5_1_5b):**

```bash
MCP_SERVER=filesystem \
TRAIN_SCOPE=filesystem \
SYSTEM_PROMPT_FILE=scripts_training/servers/filesystem/prompts/filesystem_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

**Git MCP (12 tools — recommended: qwen2_5_1_5b):**

```bash
MCP_SERVER=git \
TRAIN_SCOPE=git \
SYSTEM_PROMPT_FILE=scripts_training/servers/git/prompts/git_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

**SSH MCP (9 tools — recommended: qwen2_5_1_5b):**

```bash
MCP_SERVER=ssh \
TRAIN_SCOPE=ssh \
SYSTEM_PROMPT_FILE=scripts_training/servers/ssh/prompts/ssh_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

Each command runs:

- dataset preflight
- MLX LoRA training
- adapter fusion
- GGUF conversion
- Ollama registration when enabled
- quality gate

Useful variants (shown for weathersensorsmcp; same pattern applies to other scopes):

```bash
# Smaller experimental preset
MCP_SERVER=weathersensorsmcp \
TRAIN_SCOPE=weathersensorsmcp \
SYSTEM_PROMPT_FILE=scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b

# Reuse existing adapters
MCP_SERVER=weathersensorsmcp \
TRAIN_SCOPE=weathersensorsmcp \
SYSTEM_PROMPT_FILE=scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b --skip-train

# Register an existing GGUF only
bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b --only-ollama

# Skip the quality gate during iteration
bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b --skip-quality-gate
```

Expected artifact locations for the weather sensors scope depend on preset, for example:

- `scripts_training/weathersensorsmcp/mcp_adapters_qwen2_5_3b/`
- `scripts_training/weathersensorsmcp/mcp_fused_model_qwen2_5_3b/`
- `scripts_training/weathersensorsmcp/mcp_adapters_qwen2_5_1_5b/`
- `scripts_training/weathersensorsmcp/mcp_fused_model_qwen2_5_1_5b/`

For weatherforecast, webcrawl, filesystem, and git, artifacts land under `scripts_training/servers/{scope}/outputs/`.

### 4. Run the quality gate manually

The gate sends probes at `temperature=0.0, top_p=0.1` to enforce fully deterministic output — tool calls
require exact token reproduction and any non-zero temperature introduces format drift.

For the weathersensorsmcp 3B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen2.5-3b-weathersensorsmcp \
  --profile weathersensorsmcp
```

For the weathersensorsmcp 1.5B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen25-1p5b-weathersensorsmcp \
  --profile weathersensorsmcp
```

For the weatherforecast 1.5B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen25-1p5b-weatherforecast \
  --profile weatherforecast_text_tool_call
```

For the webcrawl 1.5B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen25-1p5b-webcrawl \
  --profile webcrawl_text_tool_call
```

For the filesystem 1.5B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen25-1p5b-filesystem \
  --profile filesystem_text_tool_call
```

For the git 1.5B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen25-1p5b-git \
  --profile git_text_tool_call
```

For the ssh 1.5B preset:

```bash
scripts_training/.venv/bin/python scripts_training/quality_gate/py/quality_gate.py \
  --model qwen25-1p5b-ssh \
  --profile ssh_text_tool_call
```

---

## Mac Workflow — Unsloth Studio (GUI Path)

Unsloth Studio is a local web UI that wraps the same QLoRA training pipeline without requiring any terminal commands after the initial dataset generation. It runs entirely on your Mac (Apple Silicon) and supports GGUF export with Ollama registration.

**When to use this path:**
- You want a visual loss curve during training
- You are iterating quickly on hyperparameters without editing shell scripts
- You prefer not to manage a Python venv

**Limitation:** Unsloth Studio's bundled `llama.cpp` lags behind the latest model releases. As of May 2026, **Phi-4-mini GGUF export fails** due to an unsupported `embed_tokens.biases` tensor. Use **Llama 3.2** or **Qwen 2.5** family models — both export cleanly.

### 1. Install Unsloth Studio

```bash
curl -fsSL https://raw.githubusercontent.com/unslothai/unsloth/main/unsloth_studio/install.sh | sh
```

After installation, launch with:

```bash
~/.unsloth/studio/unsloth_studio/bin/unsloth-studio
```

The Studio UI is available at `http://localhost:5173` (or the port shown in terminal output).

### 2. Generate the dataset (terminal — same as the scripts path)

The dataset files are generated the same way regardless of which training path you use:

```bash
source scripts_training/.venv/bin/activate

# Single-pass
bash scripts_training/generate/weathersensorsmcp/run_generate.sh

# Or incremental (recommended for larger datasets)
TOTAL=1500 MIN_VALID=1250 TOOLS_PER_CHUNK=5 EXAMPLES_PER_CHUNK=90 ATTEMPTS_PER_CHUNK=4 \
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```

This produces:
- `scripts_training/weathersensorsmcp/mcp_out/train.jsonl` — raw source (do not use directly for training)
- `scripts_training/weathersensorsmcp/mcp_out/train_split.jsonl` — training set (deduplicated, shuffled)
- `scripts_training/weathersensorsmcp/mcp_out/valid_split.jsonl` — eval set (clean, no leakage)

> **Note on deduplication:** The split step in `train.py` automatically deduplicates `train.jsonl` before splitting. This removes repeated seed examples that would otherwise cause eval loss contamination (eval loss artificially lower than train loss). Always use `train_split.jsonl` / `valid_split.jsonl` — never feed `train.jsonl` directly into a trainer.

### 3. System Prompt Injection for Unsloth Studio

The generated JSONL files (`train_split.jsonl`, `valid_split.jsonl`) contain **user/assistant messages only** — the system prompt is not embedded. Unsloth Studio expects a `system` role prepended to every conversation for the model to learn the tool-calling rules.

Use the [`inject_system_prompt.py`](common/py/dataset/inject_system_prompt.py) utility to inject the system prompt before uploading:

```bash
# For SSH (example)
python scripts_training/common/py/dataset/inject_system_prompt.py \
  --train-in servers/ssh/datasets/text_tool_call/train_split.jsonl \
  --valid-in servers/ssh/datasets/text_tool_call/valid_split.jsonl \
  --system-prompt servers/ssh/prompts/ssh_system_prompt.md \
  --train-out servers/ssh/datasets/text_tool_call/train_split_with_system.jsonl \
  --valid-out servers/ssh/datasets/text_tool_call/valid_split_with_system.jsonl

# For any other scope (filesystem, git, webcrawl, weatherforecast)
python scripts_training/common/py/dataset/inject_system_prompt.py \
  --train-in servers/{scope}/datasets/text_tool_call/train_split.jsonl \
  --valid-in servers/{scope}/datasets/text_tool_call/valid_split.jsonl \
  --system-prompt servers/{scope}/prompts/{scope}_system_prompt.md \
  --train-out servers/{scope}/datasets/text_tool_call/train_split_with_system.jsonl \
  --valid-out servers/{scope}/datasets/text_tool_call/valid_split_with_system.jsonl
```

This produces `*_with_system.jsonl` files where every conversation starts with:
```json
{"role": "system", "content": "# ROLE\nYou are an SSH/SFTP Remote Server Assistant..."}
```

**Alternative — notebook approach (Colab):** The existing Colab notebooks inject the system prompt at runtime in Cell 6 via the `format_example()` function — it checks if the first message has `role: "system"` and prepends one if missing. In that case, upload the plain `train_split.jsonl` and set `SYSTEM_PROMPT_FILE` to point to the uploaded system prompt on Google Drive.

### 4. Configure and run training in Unsloth Studio

Open the Studio UI and configure the **Fine-tuning Studio** screen:

**Model section:**
- Hugging Face Model: `mlx-community/Llama-3.2-3B-Instruct-4bit`
- Method: `QLoRA (4-bit)`

**Dataset section:**
- Choose dataset: `Local`
- Training dataset (Advanced): `train_split.jsonl` — browse to `scripts_training/weathersensorsmcp/mcp_out/train_split.jsonl`
- Eval dataset: `valid_split.jsonl` — browse to `scripts_training/weathersensorsmcp/mcp_out/valid_split.jsonl`

**Parameters section:**

| Setting | Value | Notes |
|---|---|---|
| Use Epochs | **3** | Do NOT set Max Steps — leave it blank or 0, or it overrides epochs |
| Context Length | 2048 | Sufficient for weather tool calls |
| Learning Rate | 0,0001 | 1e-4; use European decimal format in the UI |

**LoRA Settings (expand):**

| Setting | Value |
|---|---|
| Rank | 16 |
| Alpha | 16 |
| Dropout | 0.00 |
| Target Modules | q_proj, k_proj, v_proj, o_proj, gate_proj, up_proj, down_proj |

**Training Hyperparameters (expand):**

| Setting | Value |
|---|---|
| Optimizer | AdamW 8-bit |
| LR Scheduler | Linear |
| Batch Size | 2 |
| Grad Accum | 4 |

With 1,090 training examples and batch size 2 × grad accum 4 = effective batch 8:
$$\text{steps} = \frac{1090}{8} \times 3 \approx 409 \text{ steps}$$

Click **Start Training**. Expected time on Apple Silicon M-series: ~25–40 minutes.

Upload the `*_with_system.jsonl` files as the Training and Eval datasets.

### 5. Interpret the training curves

A healthy run looks like:

- **Training loss**: smooth descent from ~5–7 down to ~0.2–0.5. No upward trend at the end.
- **Eval loss**: also decreasing, slightly lower than or close to train loss. If eval loss is significantly *below* train loss from the start and stays there — that is a data contamination signal (eval examples leaked into training data).
- **Gradient norm**: one spike at step 1 (normal), then stabilises to a flat band around 0.5–2.0 for the rest of the run. If it climbs continuously toward 10+ the learning rate is too high.

If the loss explodes or the run completes in only 3 steps, check: **Max Steps is overriding the epoch count.** Clear the Max Steps field and rerun.

### 6. Export to GGUF

After training completes, click **Export Model**.

- **Checkpoint**: select the top entry (full run checkpoint, not a mid-run checkpoint) unless eval loss was rising at the end
- **Export Method**: `GGUF / Llama.cpp`
- **Quantization**: select `Q4_K_M` (~4.8 GB) for Ollama; optionally also `Q5_K_M` for higher quality

Click **Export Model** and wait for the GGUF files to appear in `~/.unsloth/studio/exports/`.

### 7. Register with Ollama

Create a Modelfile:

```
FROM /Users/laszloschaffer/.unsloth/studio/exports/<your-export-folder>/model/<model-name>-q4_k_m.gguf

SYSTEM """<paste your system prompt here>"""

PARAMETER temperature 0.0
PARAMETER top_p 0.1
PARAMETER stop "<|eot_id|>"
PARAMETER stop "<|end_of_text|>"
```

Register and test:

```bash
ollama create llama32-3b-weathersensorsmcp -f /path/to/Modelfile
ollama run llama32-3b-weathersensorsmcp "Get the latest data for station Berlin"
```

### 8. Run the quality gate

```bash
source scripts_training/.venv/bin/activate
python scripts_training/quality_gate/py/quality_gate.py \
  --model llama32-3b-weathersensorsmcp \
  --profile weathersensorsmcp
```

## Colab Workflow

Colab notebooks cover the dataset with different model families and server scopes:

| Notebook | Model | Server Scope | Notes |
|---|---|---|---|
| `text_tool_call/weathersensorsmcp_qwen_train.ipynb` | `unsloth/Qwen3-4B` | weathersensorsmcp | **Default — has video walkthrough** |
| `text_tool_call/weathersensorsmcp_ministral_train.ipynb` | `unsloth/Ministral-3-3B-Instruct-2512` | weathersensorsmcp | Alternative — simpler setup, no thinking mode |
| `text_tool_call/weatherforecast_qwen_train.ipynb` | `unsloth/Qwen2.5-1.5B-Instruct` | weatherforecast | Lightweight 4-tool set |
| `text_tool_call/webcrawl_qwen_train.ipynb` | `unsloth/Qwen2.5-1.5B-Instruct` | webcrawl | 6-tool website indexing set |
| `ollama_native/weathersensorsmcp_qwen_train.ipynb` | `unsloth/Qwen3-4B` | weathersensorsmcp | Native Ollama contract |
| `ollama_native/weathersensorsmcp_ministral_train.ipynb` | `unsloth/Ministral-3-3B-Instruct-2512` | weathersensorsmcp | Native Ollama + Ministral |
| `ollama_native/weatherforecast_qwen_train.ipynb` | `unsloth/Qwen2.5-1.5B-Instruct` | weatherforecast | Native Ollama, 4-tool set |
| `ollama_native/webcrawl_qwen_train.ipynb` | `unsloth/Qwen2.5-1.5B-Instruct` | webcrawl | Native Ollama, 6-tool set |

### 1. Generate the dataset locally

**For weathersensorsmcp Qwen3-4B (default):**

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate.sh
# or incremental:
TOTAL=1500 MIN_VALID=1250 TOOLS_PER_CHUNK=5 EXAMPLES_PER_CHUNK=90 ATTEMPTS_PER_CHUNK=4 \
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```
Outputs to `weathersensorsmcp/mcp_out/`. Upload to `MyDrive/training/weathersensorsmcp/mcp_out/` and also upload `weather_sensors_system_prompt.md`.

**For weathersensorsmcp Ministral 3B:**

```bash
bash scripts_training/generate/weathersensorsmcp/run_generate_ministral.sh
# or incremental:
TOTAL=600 MIN_VALID=400 bash scripts_training/generate/weathersensorsmcp/run_generate_ministral_incremental.sh
```
Outputs to `weathersensorsmcp/mcp_out_ministral/`. Upload to `MyDrive/training/weathersensorsmcp/mcp_out_ministral/`.

**For weatherforecast (4-tool set, text_tool_call):**

```bash
bash scripts_training/generate/weatherforecast/run_generate.sh
# or incremental:
bash scripts_training/generate/weatherforecast/run_generate_incremental.sh
```

**For webcrawl (6-tool set, text_tool_call):**

```bash
bash scripts_training/generate/webcrawl/run_generate.sh
# or incremental:
bash scripts_training/generate/webcrawl/run_generate_incremental.sh
```

### 2. Open the notebook in Colab

**Default — Qwen3-4B** ([video walkthrough](https://youtu.be/jsiZAsctTyg)):

- `scripts_training/notebooks/text_tool_call/weathersensorsmcp_qwen_train.ipynb`
- model: `unsloth/Qwen3-4B`, data: `weathersensorsmcp/mcp_out`, HF: `lschaffer/qwen3-4b-weathersensorsmcp`
- `chat_template='chatml'` suppresses thinking mode

**Ministral 3B:**

- `scripts_training/notebooks/text_tool_call/weathersensorsmcp_ministral_train.ipynb`
- model: `unsloth/Ministral-3-3B-Instruct-2512`, data: `weathersensorsmcp/mcp_out_ministral`, HF: `lschaffer/ministral-3b-weathersensorsmcp`
- `chat_template='mistral'` — no thinking mode, no override needed

**Weather Forecast (1.5B):**

- `scripts_training/notebooks/text_tool_call/weatherforecast_qwen_train.ipynb`
- model: `unsloth/Qwen2.5-1.5B-Instruct`, data: `servers/weatherforecast/datasets/text_tool_call/`, HF: `lschaffer/qwen25-1p5b-weatherforecast`

**Web Crawl (1.5B):**

- `scripts_training/notebooks/text_tool_call/webcrawl_qwen_train.ipynb`
- model: `unsloth/Qwen2.5-1.5B-Instruct`, data: `servers/webcrawl/datasets/text_tool_call/`, HF: `lschaffer/qwen25-1p5b-webcrawl`

Native Ollama notebooks are also available under `scripts_training/notebooks/ollama_native/`.

### 3. Notebook flow

1. Install Unsloth and clear the cached `llama.cpp` checkout.
2. Configure the preset-specific paths (Cell 2).
3. Mount Drive and verify the dataset and system prompt files.
4. Load the model in `bfloat16`.
5. Apply LoRA (`r=16`, standard transformer target modules).
6. Load the dataset and inject the system prompt.
7. Train (3 epochs, LR 2e-4, batch 4).
8. Save adapters; export GGUF natively via Unsloth (with `llama.cpp` fallback).
9. Generate a model card with the Modelfile template.
10. Upload to Hugging Face.

### 4. Reuse Colab adapters on Mac

```bash
MCP_SERVER=weathersensorsmcp \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b --skip-train \
  --download-hf-adapters your-user/your-repo --hf-adapter-subdir adapters
```

## Current Scripts

### Main shell scripts

| File | Purpose |
|---|---|
| `bootstrap_venv_mac.sh` | Creates the local Apple Silicon MLX environment. |
| `generate/run_generate.sh` | Generic dataset generation launcher — pass any MCP tools JSON/JSONL schema as argument. |
| `generate/weathersensorsmcp/run_generate.sh` | Single-pass weather dataset generation (standard Qwen/Ministral format). |
| `generate/weathersensorsmcp/run_generate_incremental.sh` | Semantic incremental weather dataset generation with family-based chunking. |
| `generate/weathersensorsmcp/run_generate_ministral.sh` | Single-pass weather dataset generation for the Ministral path (outputs to `mcp_out_ministral/`). |
| `generate/weathersensorsmcp/run_generate_ministral_incremental.sh` | Incremental weather dataset generation for the Ministral path (outputs to `mcp_out_ministral/`). |
| `generate/weathersensorsmcp/run_generate_ollama_native.sh` | Single-pass native-contract weather dataset generation. |
| `generate/weathersensorsmcp/run_generate_ollama_native_incremental.sh` | Incremental native-contract weather dataset generation. |
| `generate/ssh/run_generate.sh` | Single-pass SSH dataset generation (text_tool_call). |
| `generate/ssh/run_generate_incremental.sh` | Incremental SSH dataset generation (text_tool_call). |
| `generate/ssh/run_generate_ollama_native.sh` | Single-pass SSH native-contract generation. |
| `generate/ssh/run_generate_ollama_native_incremental.sh` | Incremental SSH native-contract generation. |
| `generate/weatherforecast/run_generate.sh` | Single-pass weatherforecast dataset generation (text_tool_call). |
| `generate/weatherforecast/run_generate_incremental.sh` | Incremental weatherforecast dataset generation (text_tool_call). |
| `generate/weatherforecast/run_generate_ollama_native.sh` | Single-pass weatherforecast native-contract generation. |
| `generate/weatherforecast/run_generate_ollama_native_incremental.sh` | Incremental weatherforecast native-contract generation. |
| `generate/webcrawl/run_generate.sh` | Single-pass webcrawl dataset generation (text_tool_call). |
| `generate/webcrawl/run_generate_incremental.sh` | Incremental webcrawl dataset generation (text_tool_call). |
| `generate/webcrawl/run_generate_ollama_native.sh` | Single-pass webcrawl native-contract generation. |
| `generate/webcrawl/run_generate_ollama_native_incremental.sh` | Incremental webcrawl native-contract generation. |
| `train/train_mcp.sh` | Main local pipeline: preflight, train, fuse, GGUF, Ollama, quality gate, HF helpers. |
| `quality_gate/run_qwen3_quality_gate.sh` | Download Qwen3-4B GGUF from HF (or use local), register with Ollama, run quality gate. |
| `quality_gate/run_ministral_quality_gate.sh` | Download Ministral GGUF from HF (or use local), register with Ollama, run quality gate. |
| `train/upload_gguf_to_tealkit.sh` | Upload helper for shipping a GGUF to the app server. |
| `download_mlx_models_mac.sh` | Downloads MLX model repos for the supported presets. |
| `download-hf-model.sh` | Downloads GGUF + Modelfile from HuggingFace and registers with Ollama (Mac/Linux). |
| `download-hf-model.ps1` | Downloads GGUF + Modelfile from HuggingFace and registers with Ollama (Windows PowerShell). |

### Main Python scripts

| File | Purpose |
|---|---|
| `generate_train_jsonl_gemini.py` | Generates a full training dataset with Gemini in one pass. |
| `generate_train_jsonl_gemini_incremental.py` | Generates training data with semantic tool families, dedupes it, validates it, and prints coverage summaries. |
| `generate_starter_jsonl.py` | Produces a minimal starter dataset for smoke tests. |
| `validate_jsonl.py` | Validates training rows, canonical tool-call shape, tool names, and parameters. |
| `train.py` | Builds prompts, validates datasets, and splits train/valid JSONL files. |
| `train_lora.py` | Standalone Unsloth / CUDA LoRA training path. |
| `quality_gate.py` | Runs local evaluation probes against an Ollama model. |
| `convert_to_csv.py` | Converts dataset outputs to CSV. |
| `convert_to_csv_clean.py` | CSV conversion helper with cleanup formatting. |
| `convert_to_hf_format.py` | Converts data into a Hugging Face-friendly format. |
| `convert_to_unsloth_native.py` | Converts data into the format expected by the Unsloth path. |
| `inject_system_prompt.py` | Injects system prompt into JSONL — prepends `{"role": "system", "content": "..."}` to every conversation for Unsloth Studio. |

### Support files

| File | Purpose |
|---|---|
| `README_DOWNLOAD_MODELS.md` | Complete documentation for downloading trained models from HuggingFace to Ollama. |
| `train.md` | Base prompt template for the generic dataset generator. |
| `train_prompt.md` | Older generic prompt template still kept in the repo. |
| `patch_notebook.py` | Notebook patch helper kept from earlier iterations. |
| `export_mcp_tools.dart` | Exports MCP tool schemas for training data generation. |
| `export_mcp_tools_test.dart` | Test helper for the MCP export script. |
| `_write_readme.py` | Legacy helper kept for reference; this README is maintained manually. |

### Internal helpers under `py/`

| File | Purpose |
|---|---|
| `py/adapter_compatibility.py` | Checks whether adapter dimensions match the selected base model. |
| `py/dataset_preflight.py` | Verifies training split structure before local training starts. |
| `py/detect_adapter_layout.py` | Detects whether adapters are MLX or PEFT style. |
| `py/download_hf_adapters.py` | Downloads adapters from Hugging Face. |
| `py/merge_peft_adapter.py` | Merges a PEFT adapter into a full model checkpoint. |
| `py/mlx_generate_test.py` | Runs a quick MLX inference sanity check. |
| `py/mlx_output_check.py` | Checks MLX outputs for bad formatting or degeneration. |
| `py/patch_tokenizer_config.py` | Applies the tokenizer regex workaround where needed. |
| `py/prepare_mlx_chat_data.py` | Injects the training system prompt into MLX JSONL data. |
| `py/rewrite_tokenizer_fix.py` | Rewrites tokenizer files with the fix applied. |

## Current Notebooks

| File | Purpose |
|---|---|
| `notebooks/text_tool_call/weathersensorsmcp_qwen_train.ipynb` | Weather Sensors MCP — Qwen3-4B Colab training (Unsloth, ChatML, thinking suppressed, native GGUF export, HF upload). Default path with video. |
| `notebooks/text_tool_call/weathersensorsmcp_ministral_train.ipynb` | Weather Sensors MCP — Ministral 3B Colab training (Unsloth, Mistral `[INST]` template, native GGUF export, HF upload). Alternative path. |
| `notebooks/text_tool_call/weatherforecast_qwen_train.ipynb` | Weather Forecast MCP — Qwen2.5-1.5B Colab training (4 tools, lightweight). |
| `notebooks/text_tool_call/webcrawl_qwen_train.ipynb` | Web Crawl MCP — Qwen2.5-1.5B Colab training (6 tools, website indexing). |
| `notebooks/ollama_native/weathersensorsmcp_qwen_train.ipynb` | Weather Sensors MCP — Qwen3-4B, native Ollama contract. |
| `notebooks/ollama_native/weathersensorsmcp_ministral_train.ipynb` | Weather Sensors MCP — Ministral 3B, native Ollama contract. |
| `notebooks/ollama_native/weatherforecast_qwen_train.ipynb` | Weather Forecast MCP — Qwen2.5-1.5B, native Ollama contract. |
| `notebooks/ollama_native/webcrawl_qwen_train.ipynb` | Web Crawl MCP — Qwen2.5-1.5B, native Ollama contract. |

## Recommended Starting Points

### Local Mac — terminal / scripts path (weathersensorsmcp)

```bash
bash scripts_training/bootstrap_venv_mac.sh
source scripts_training/.venv/bin/activate
TOTAL=1500 MIN_VALID=1250 TOOLS_PER_CHUNK=5 EXAMPLES_PER_CHUNK=90 ATTEMPTS_PER_CHUNK=4 \
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh

MCP_SERVER=weathersensorsmcp \
TRAIN_SCOPE=weathersensorsmcp \
SYSTEM_PROMPT_FILE=scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b
```

### Local Mac — terminal / scripts path (weatherforecast)

```bash
source scripts_training/.venv/bin/activate
export DEEPSEEK_API_KEY="your_key_here"
bash scripts_training/generate/weatherforecast/run_generate.sh

MCP_SERVER=weatherforecast \
TRAIN_SCOPE=weatherforecast \
SYSTEM_PROMPT_FILE=scripts_training/servers/weatherforecast/prompts/weatherforecast_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

### Local Mac — terminal / scripts path (webcrawl)

```bash
source scripts_training/.venv/bin/activate
export DEEPSEEK_API_KEY="your_key_here"
bash scripts_training/generate/webcrawl/run_generate.sh

MCP_SERVER=webcrawl \
TRAIN_SCOPE=webcrawl \
SYSTEM_PROMPT_FILE=scripts_training/servers/webcrawl/prompts/webcrawl_system_prompt.md \
bash scripts_training/train/train_mcp.sh --preset qwen2_5_1_5b
```

### Local Mac — Unsloth Studio path

```bash
# 1. Generate the dataset (one-time terminal step)
source scripts_training/.venv/bin/activate
TOTAL=1500 MIN_VALID=1250 TOOLS_PER_CHUNK=5 EXAMPLES_PER_CHUNK=90 ATTEMPTS_PER_CHUNK=4 \
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh

# 2. Launch Unsloth Studio
~/.unsloth/studio/unsloth_studio/bin/unsloth-studio
# → open http://localhost:5173
# → model: mlx-community/Llama-3.2-3B-Instruct-4bit
# → training: train_split.jsonl, eval: valid_split.jsonl
# → epochs: 3, LR: 0,0001, rank: 16
# → Export → GGUF → Q4_K_M
```

### Colab path — Qwen3-4B (default, has video)

```bash
TOTAL=1500 MIN_VALID=1250 TOOLS_PER_CHUNK=5 EXAMPLES_PER_CHUNK=90 ATTEMPTS_PER_CHUNK=4 \
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```

Upload `mcp_out/` and `weather_sensors_system_prompt.md` to `MyDrive/training/weathersensorsmcp/`, then open `scripts_training/notebooks/text_tool_call/weathersensorsmcp_qwen_train.ipynb` in Colab ([video walkthrough](https://youtu.be/jsiZAsctTyg)). After the final cell finishes uploading, run the quality gate:

```bash
bash scripts_training/quality_gate/run_qwen3_quality_gate.sh --from-hf
```

### Colab path — Ministral 3B (alternative)

**For Text Tool Call:**
```bash
TOTAL=600 MIN_VALID=400 bash scripts_training/generate/weathersensorsmcp/run_generate_ministral_incremental.sh
```

**For Native Ollama:**
```bash
TOTAL=600 MIN_VALID=400 bash scripts_training/generate/weathersensorsmcp/run_generate_ministral_ollama_native_incremental.sh
```

Upload `mcp_out_ministral/` and `weather_sensors_system_prompt.md` to `MyDrive/training/weathersensorsmcp/`, then open `scripts_training/notebooks/text_tool_call/weathersensorsmcp_ministral_train.ipynb` (or the native version under `ollama_native/`) in Colab. After the final cell finishes uploading, run the quality gate:

```bash
bash scripts_training/quality_gate/run_ministral_quality_gate.sh --from-hf
```

### Colab path — Weather Forecast (1.5B)

```bash
bash scripts_training/generate/weatherforecast/run_generate.sh
```

Upload `servers/weatherforecast/datasets/text_tool_call/` and the weatherforecast system prompt to `MyDrive/training/weatherforecast/`, then open `scripts_training/notebooks/text_tool_call/weatherforecast_qwen_train.ipynb` in Colab.

### Colab path — Web Crawl (1.5B)

```bash
bash scripts_training/generate/webcrawl/run_generate.sh
```

Upload `servers/webcrawl/datasets/text_tool_call/` and the webcrawl system prompt to `MyDrive/training/webcrawl/`, then open `scripts_training/notebooks/text_tool_call/webcrawl_qwen_train.ipynb` in Colab.

### Colab path — SSH (1.5B)

```bash
bash scripts_training/generate/ssh/run_generate.sh
```

Upload `servers/ssh/datasets/text_tool_call/` and the SSH system prompt to `MyDrive/training/ssh/`, then open an existing notebook (e.g. `webcrawl_qwen_train.ipynb`) as a template — change `DATA_DIR`, `SYSTEM_PROMPT_FILE`, `OUTPUT_DIR`, `GGUF_DIR`, and `HF_REPO` to the SSH paths.

## Uploading Trained Models to HuggingFace

After training completes, you can upload the GGUF, Modelfile, and model card to HuggingFace. There are two paths:

### Option A: Upload via `train_mcp.sh` (recommended for local Mac training)

If you run the full pipeline with `--upload-hf`, the script automatically uploads after GGUF conversion:

```bash
# Full pipeline with upload
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --preset qwen2_5_3b \
  --upload-hf \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp
```

Upload-only mode (if GGUF already exists from a previous run):

```bash
bash scripts_training/train/train_mcp.sh \
  --preset qwen2_5_3b \
  --only-hf-upload \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp
```

For `ollama_native` contracts (model name gets `-ollama` suffix automatically):

```bash
bash scripts_training/train/train_mcp.sh \
  --contract-type ollama_native \
  --preset qwen2_5_3b \
  --upload-hf \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp-ollama
```

The script uploads:
- **GGUF** (Q5_K_M or F16) — model weights
- **Modelfile** — Ollama template with tool support
- **README.md** — Auto-generated model card with system prompt, usage instructions, and download links

### Option B: Upload via Colab notebook (recommended for Colab training)

The last cell of each notebook in `notebooks/` handles HF upload directly via `huggingface_hub`. After training and GGUF export, the notebook pushes GGUF + Modelfile to your HF repo. Configure the target repo in the notebook's setup cell.

### Generic MCP server presets (filesystem & git)

These presets are for **anyone** using the popular [`filesystem`](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) and [`git`](https://github.com/modelcontextprotocol/servers/tree/main/src/git) MCP servers — free, usable with any agentic app from OpenClaw to Claude Desktop:

```bash
# Train filesystem server (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope filesystem \
  --preset qwen2_5_1_5b

# Upload filesystem GGUF
bash scripts_training/train/train_mcp.sh \
  --server-scope filesystem \
  --preset qwen2_5_1_5b \
  --only-hf-upload \
  --hf-repo your-user/qwen25-1p5b-filesystem

# Train git server (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope git \
  --preset qwen2_5_1_5b

# Upload git GGUF
bash scripts_training/train/train_mcp.sh \
  --server-scope git \
  --preset qwen2_5_1_5b \
  --only-hf-upload \
  --hf-repo your-user/qwen25-1p5b-git
```

### TealKit inbuilt MCP tools (webcrawl & weatherforecast)

These presets are for the built-in TealKit MCP servers:

```bash
# weatherforecast (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope weatherforecast \
  --preset qwen2_5_1_5b \
  --upload-hf \
  --hf-repo your-user/qwen25-1p5b-weatherforecast

# webcrawl (1.5B)
bash scripts_training/train/train_mcp.sh \
  --server-scope webcrawl \
  --preset qwen2_5_1_5b \
  --upload-hf \
  --hf-repo your-user/qwen25-1p5b-webcrawl
```

### External MCP server tested with TealKit (weathersensorsmcp)

These presets are for the external proprietary weather sensor MCP server tested with TealKit:

```bash
# Full pipeline with upload (weathersensorsmcp, 3B)
bash scripts_training/train/train_mcp.sh \
  --contract-type text_tool_call \
  --server-scope weathersensorsmcp \
  --preset qwen2_5_3b \
  --upload-hf \
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
| weathersensorsmcp (3B, ollama_native) | External (proprietary) tested with TealKit | `lschaffer/qwen2.5-3b-weathersensorsmcp-ollama` |
| weathersensorsmcp (Ministral 3B) | External (proprietary) tested with TealKit | `lschaffer/ministral-3b-weathersensorsmcp` |

### Private repos

Use `--hf-private` to create the repo as private:

```bash
bash scripts_training/train/train_mcp.sh \
  --preset qwen2_5_3b \
  --upload-hf \
  --hf-repo your-user/private-model \
  --hf-private
```

### Generate model card only

If you want to generate or preview the model card without uploading:

```bash
bash scripts_training/train/train_mcp.sh \
  --preset qwen2_5_3b \
  --only-generate-card \
  --hf-repo your-user/qwen2.5-3b-weathersensorsmcp
```

---

## Downloading Trained Models from HuggingFace

After training and uploading models to HuggingFace, you (or other users) need to download **both the GGUF and Modelfile** to use the model with Ollama. Downloading only the GGUF will result in a "not tool capable" error.

**Why both files?**
- **GGUF file** → The quantized model weights
- **Modelfile** → Contains the TEMPLATE directive that enables tool calling in Ollama

### Quick Start

**Windows (PowerShell):**
```powershell
# Qwen2.5-3B (weathersensorsmcp)
.\scripts_training\download-hf-model.ps1 -Repo "username/qwen2.5-3b-weathersensorsmcp"

# Ministral-3B (weathersensorsmcp)
.\scripts_training\download-hf-model.ps1 -Repo "username/ministral-3b-weathersensorsmcp"

# Qwen2.5-1.5B (weatherforecast)
.\scripts_training\download-hf-model.ps1 -Repo "username/qwen25-1p5b-weatherforecast"

# Qwen2.5-1.5B (webcrawl)
.\scripts_training\download-hf-model.ps1 -Repo "username/qwen25-1p5b-webcrawl"
```

**Mac/Linux (Bash):**
```bash
# Make executable first
chmod +x scripts_training/download-hf-model.sh

# Qwen2.5-3B (weathersensorsmcp)
./scripts_training/download-hf-model.sh username/qwen2.5-3b-weathersensorsmcp

# Ministral-3B (weathersensorsmcp)
./scripts_training/download-hf-model.sh username/ministral-3b-weathersensorsmcp

# Qwen2.5-1.5B (weatherforecast)
./scripts_training/download-hf-model.sh username/qwen25-1p5b-weatherforecast

# Qwen2.5-1.5B (webcrawl)
./scripts_training/download-hf-model.sh username/qwen25-1p5b-webcrawl
```

### What the Scripts Do

1. Fetch file list from HuggingFace repository
2. Find GGUF file matching pattern (default: `*q5_k_m.gguf`)
3. Verify Modelfile exists
4. Download both GGUF and Modelfile to `./hf_models/<repo-name>/`
5. Register with Ollama using the Modelfile (enables tool support)
6. Verify registration successful

### Options

**PowerShell:**
```powershell
# Use different quantization (F16 instead of Q5)
.\scripts_training\download-hf-model.ps1 -Repo "username/model-name" -GgufPattern "*f16.gguf"

# Override local model name
.\scripts_training\download-hf-model.ps1 -Repo "username/model-name" -ModelName "my-custom-name"

# Custom output directory
.\scripts_training\download-hf-model.ps1 -Repo "username/model-name" -OutputDir "C:\my-models"
```

**Bash:**
```bash
# Use different quantization (F16 instead of Q5)
./scripts_training/download-hf-model.sh username/model-name "" "*f16.gguf"

# Override local model name
./scripts_training/download-hf-model.sh username/model-name my-custom-name

# Bash doesn't support custom output directory - edit the script if needed
```

### Forcing Model Updates / Removing Old GGUF Cache
When you retrain and push a new model update to HuggingFace, the download script will skip downloading the GGUF if it already exists in the cache folder. To force download the updated model weights, delete the old cached GGUF file locally before running the download script:

```bash
# Weather Sensors MCP (3B)
rm -f ./hf_models/qwen2.5-3b-weathersensorsmcp-ollama/qwen2.5-3b-weathersensorsmcp-ollama-q5_k_m.gguf
./scripts_training/download-hf-model.sh lschaffer/qwen2.5-3b-weathersensorsmcp-ollama

# Weather Forecast (1.5B)
rm -f ./hf_models/qwen25-1p5b-weatherforecast-ollama/qwen25-1p5b-weatherforecast-ollama-q5_k_m.gguf
./scripts_training/download-hf-model.sh lschaffer/qwen25-1p5b-weatherforecast-ollama

# Web Crawl (1.5B)
rm -f ./hf_models/qwen25-1p5b-webcrawl-ollama/qwen25-1p5b-webcrawl-ollama-q5_k_m.gguf
./scripts_training/download-hf-model.sh lschaffer/qwen25-1p5b-webcrawl-ollama
```

### Available Quantizations

| Pattern | File Size | Quality | Use Case |
|---------|-----------|---------|----------|
| `*q5_k_m.gguf` | ~2.3 GB | High (recommended) | Best balance for production |
| `*q4_k_m.gguf` | ~1.9 GB | Good | Smaller, faster inference |
| `*f16.gguf` | ~6.7 GB | Maximum | Full precision (no quantization) |

### Testing Tool Support

After registration:
```bash
ollama run model-name "What tools do you have?"
```

### Full Documentation

See [README_DOWNLOAD_MODELS.md](README_DOWNLOAD_MODELS.md) for complete documentation including:
- Detailed parameter descriptions
- Troubleshooting guide
- Manual download alternative
- Output structure
