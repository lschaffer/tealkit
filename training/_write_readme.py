"""Writes the new scripts_training/README.md"""
import pathlib

README = r"""# MCP Tool-Calling Training Guide

Fine-tune a small local model (≤4B, text-only) on MCP tool calling using a
**teacher-to-student** workflow: a strong cloud LLM (Gemini) generates
high-quality training examples, and a compact on-device model (the student)
learns to reproduce the structured tool-call outputs through LoRA fine-tuning.

The result is a quantised GGUF that runs on Apple Silicon, Android, or iOS
at interactive latency — without API fees or cloud inference.

---

## Core Concepts

### Teacher-to-Student Fine-Tuning

You use a capable cloud model (the teacher) to synthesise annotated
`tool_call` / `no_tool` examples from your MCP tool schemas, then fine-tune a
small model (the student) on those examples. The student never needs to reason
from scratch — it learns to pattern-match your specific tools and their
argument shapes. This is why even a 3B model can reach near-perfect tool-call
fidelity on a domain-specific schema after a modest dataset (~300–1000 rows).

### GGUF

GGUF is the file format used by `llama.cpp`-style runtimes (Ollama, LM Studio,
on-device apps). It bundles weights and tokeniser metadata into a single
runtime-friendly file. Quantised GGUFs (Q4_K_M, Q5_K_M) are 2–4× smaller than
the original float16 weights while losing minimal output quality.

### LoRA and Adapters

LoRA (Low-Rank Adaptation) fine-tunes a model by learning small *adapter*
matrices instead of rewriting all base weights. Benefits: lower VRAM, faster
training, base model stays intact. After training you can either keep adapters
separate or **fuse** them into a new full-weight checkpoint for GGUF export.

Adapter rank (`r`) is the key hyperparameter:

| Rank | VRAM | Capacity | Starting point |
|---|---|---|---|
| `r=8` | lowest | compact | Gemma 4 E2B |
| `r=16` | moderate | balanced | Phi-4-mini, Qwen3-4B |
| `r=32` | higher | more capacity | large datasets / complex schemas |

### Quantization: Q4 vs Q5

| Format | RAM | Speed | Tool-call reliability |
|---|---|---|---|
| Q4_K_M | smallest | fastest | good |
| Q5_K_M | +15–20% | slightly slower | better — preferred for tool-calling |

For mobile (~12 GB device RAM): Q5 for 2B–3B models if latency allows;
fall back to Q4 if needed.

---

## Is It Worth It?

### Recommended model sizes by hardware

| Target | RAM | Recommended size | GGUF format | Notes |
|---|---|---|---|---|
| **Mobile (Android / iOS)** | 8–12 GB | 1B–3B | Q4_K_M or Q5_K_M | >3B at Q5 → latency ≥3 s/token |
| **Mac Mini M4 Pro** | 24 GB unified | 3B–4B (train); up to 14B (infer) | Q5_K_M | Metal/MLX; training ≤4B recommended |
| **Windows / Linux w/ NVIDIA GPU ≥16 GB** | 24–32 GB | 7B–14B | Q5_K_M | GPU required for usable speed |
| **Windows / Linux CPU-only** | 24–32 GB | 3B | Q4_K_M | CPU-only >3B is impractically slow |
| **Cloud GPU (Colab Pro H100)** | 80 GB | 3B–4B+ | Q5_K_M | Best quality; use H100 notebook |

Leave ~4 GB headroom for OS + runtime overhead (Ollama, KV cache).

### When fine-tuning is worth it

**Yes, if:**
- Your tool schemas are domain-specific (base models hallucinate wrong names/args)
- You need consistent output format (`tool_call: {...}` prefix, bare JSON, etc.)
- You target 1B–7B models with weak out-of-the-box tool-call fidelity

**Probably not worth it if:**
- You use a 13B+ instruct model (strong tool-call fidelity from a good system prompt)
- You only have a handful of tools — a well-crafted system prompt may suffice

### Presets in this pipeline

| Preset | Mac/MLX model | Colab/CUDA model | Size |
|---|---|---|---|
| `qwen3_4b` | `mlx-community/Qwen3-4B-4bit` | — | ~4B |
| `phi4` | `mlx-community/Phi-4-mini-instruct-4bit` | `unsloth/Phi-4-mini-instruct` | ~3.8B |
| `qwen2_5_3b` | `mlx-community/Qwen2.5-3B-Instruct-4bit` | `unsloth/Qwen2.5-3B-Instruct-bnb-4bit` | ~3B |
| `gemma4_e2b` | `mlx-community/gemma-4-e2b-it-4bit` | `unsloth/gemma-4-E2B-it` | ~2B |

> **Note:** Each model family has its own tokeniser format, chat template, and
> tool-call output convention. If you switch presets, re-validate the GGUF
> conversion and system prompt independently.

---

## Steps at a Glance

| Step | What | Section |
|------|------|---------|
| **1** | Setup Python environment (Mac arm64) | [Setup](#1-setup-python-environment-mac) |
| **2** | Prepare training files from your MCP tools JSON | [Prepare](#2-prepare-training-data) |
| **3** | Run LoRA training | [Training](#3-training) |
| **4** | Create GGUF, upload to Hugging Face | [Export and Upload](#4-export-and-upload) |

---

## 1. Setup Python Environment (Mac)

The reliable method uses `uv` with an explicit `aarch64` Python specifier.
This avoids Homebrew Python linkage issues and Rosetta/x86_64 venv problems.

```bash
# Install uv if not already present
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Install arm64 Python 3.11 explicitly
~/.local/bin/uv python install cpython-3.11-macos-aarch64-none

# Create the venv
~/.local/bin/uv venv --python cpython-3.11-macos-aarch64-none scripts_training/.venv

# Install MLX, Hugging Face tools, and Gemini client
~/.local/bin/uv pip install --python scripts_training/.venv/bin/python -U \
  pip setuptools wheel mlx-lm huggingface_hub google-generativeai

# Activate
source scripts_training/.venv/bin/activate
```

Or use the setup script:

```bash
bash scripts_training/bootstrap_venv_mac.sh
source scripts_training/.venv/bin/activate
```

> `mlx` / `mlx-lm` are Apple Silicon only — they require `arm64` and will not
> install on x86_64 (Rosetta) Python.

### Download base model (required for training)

```bash
hf auth login   # first time only

# Recommended preset: Qwen3-4B (best instruct quality ≤4B, text-only)
hf download mlx-community/Qwen3-4B-4bit

# Alternative: Phi-4-mini
hf download mlx-community/Phi-4-mini-instruct-4bit
```

---

## 2. Prepare Training Data

Generation scripts are generic — pass any MCP tools JSON as input.
Output is organized under the scope-specific `mcp_out` folder derived from the tools path.
For a tools file inside `scripts_training/<scope>/mcp_data/`, generated data lands in
`scripts_training/<scope>/mcp_out/<base-name>/`.

### One-command generation + split

```bash
export GEMINI_API_KEY="your_key"
bash scripts_training/generate/run_generate.sh \
  scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
```

This single script:
1. Builds the training prompt from `train.md` + tool schema
2. Generates `train.jsonl` via Gemini (min 300 valid examples, includes `no_tool` rows)
3. Validates the output against the tool schema
4. Splits into `train_split.jsonl` + `valid_split.jsonl`

Output in `scripts_training/weathersensorsmcp/mcp_out/`:
- `train.jsonl` — full dataset
- `train_split.jsonl` — upload to Colab as `TRAIN_FILE`
- `valid_split.jsonl` — upload to Colab as `VALID_FILE`

### Using a different tools schema

```bash
bash scripts_training/generate/run_generate.sh \
  scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
```

### Tuning via env vars

```bash
COUNT=500 MIN_VALID=400 bash scripts_training/generate/run_generate.sh \
  scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
```

### Incremental/chunked generation (better per-tool coverage)

```bash
export GEMINI_API_KEY="your_key"
bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
# Tuning:
TOTAL=420 TOOLS_PER_CHUNK=8 EXAMPLES_PER_CHUNK=40 ATTEMPTS_PER_CHUNK=2 \
  bash scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh
```

### Split only (if train.jsonl already exists)

```bash
scripts_training/.venv/bin/python scripts_training/generate/py/train.py \
  --base-name weather_sensors \
  --output-dir scripts_training/weathersensorsmcp/mcp_out \
  --split
```

---

## 3. Training

Recommended preset for text-only models ≤4B on Mac Apple Silicon: **`qwen3_4b`**

```bash
# Full pipeline: train → fuse → GGUF → Ollama
bash scripts_training/train/train_mcp.sh --preset qwen3_4b

# Phi-4-mini alternative
bash scripts_training/train/train_mcp.sh --preset phi4

# Skip training (fuse + GGUF + Ollama from existing adapters)
bash scripts_training/train/train_mcp.sh --preset qwen3_4b --skip-train

# Resume from checkpoint
bash scripts_training/train/train_mcp.sh --preset qwen3_4b --resume-adapter
```

For **Google Colab** (H100 / Colab Pro), use the notebook:
- `scripts_training/notebooks/weathersensorsmcp_ministral_train.ipynb`
- Upload `mcp_out_ministral/` to Google Drive before running
- See [Google Colab section](#colab-workflow) for full details

Weather dataset defaults to `scripts_training/weathersensorsmcp/mcp_out_ministral/`.
To train another scoped dataset, set `TRAIN_SCOPE` and optionally `DATASET_BASE_NAME`:

```bash
TRAIN_SCOPE=weathersensorsmcp bash scripts_training/train/train_mcp.sh --preset qwen2_5_3b
```

### Key flags for `train_mcp.sh`

| Flag | Description |
|---|---|
| `--preset <name>` | `qwen3_4b` \| `phi4` \| `qwen2_5_3b` \| `gemma4_e2b` |
| `--skip-train` | Fuse + GGUF + Ollama from existing adapters |
| `--skip-fuse` | GGUF + Ollama only |
| `--skip-quality-gate` | Skip Ollama quality check (e.g. Ollama not running) |
| `--mlx-test` | Run MLX inference validation before GGUF conversion |
| `--download-hf-adapters <repo>` | Download PEFT adapters from HF before fusing |
| `--resume-adapter` | Resume from existing checkpoint |

---

## 4. Export and Upload

```bash
# Generate GGUF + model card + upload to Hugging Face in one step
bash scripts_training/train/train_mcp.sh --preset qwen3_4b \
  --upload-hf --hf-repo your-user/qwen3-4b-tealkit

# Generate model card only (local preview)
bash scripts_training/train/train_mcp.sh --preset qwen3_4b --only-generate-card

# Upload GGUF only (if already trained and fused)
bash scripts_training/train/train_mcp.sh --preset qwen3_4b \
  --only-hf-upload --hf-repo your-user/qwen3-4b-tealkit
```

GGUF files are stored in preset-specific folders:
- `scripts_training/mcp_fused_model_qwen3_4b/qwen3-4b-tealkit-q5_k_m.gguf`
- `scripts_training/mcp_fused_model_phi4/phi4mini-tealkit-q5_k_m.gguf`

---

## File Reference

### Training scripts

| File | Purpose |
|---|---|
| `train_mcp.sh` | Main Mac/Apple Silicon orchestration: train → fuse → GGUF → Ollama → HF upload |
| `train.py` | Utility: build prompt, validate JSONL, split train/valid. Generic `--base-name` / `--output-dir` |
| `train_lora.py` | LoRA fine-tuning via Unsloth (CUDA / Windows / Linux GPU path) |
| `run_generate_train_jsonl.sh` | One-command launcher: pass any tools JSON; generate → validate → split |
| `run_generate_weather_train_jsonl_incremental.sh` | Incremental chunked generation for weather-sensor schema |
| `generate_train_jsonl_gemini.py` | Calls Gemini API to generate full training JSONL in one batch |
| `generate_train_jsonl_gemini_incremental.py` | Per-tool-chunk Gemini generation with merge/dedup |
| `validate_jsonl.py` | Schema-aware JSONL validator: tool names, required params, types |
| `generate_starter_jsonl.py` | Minimal starter `train.jsonl` for smoke-testing the pipeline |
| `quality_gate.py` | Probes Ollama model with tool-call prompts; blocks HF upload on failure |

### Environment / setup

| File | Purpose |
|---|---|
| `bootstrap_venv_mac.sh` | Creates arm64 Python 3.11 venv for MLX training on Apple Silicon |
| `download_mlx_models_mac.sh` | Downloads MLX quantised model repos from Hugging Face |
| `upload_gguf_to_tealkit.sh` | Uploads trained GGUF to tealkit.dev via SSH/SCP |

### Templates and schemas

| File | Purpose |
|---|---|
| `train.md` | Base prompt template used by `run_generate_train_jsonl.sh` |
| `train_prompt.md` | Legacy prompt template (kept for reference) |
| `export_mcp_tools.dart` | Exports TealKit built-in MCP tool schemas to JSON |
| `tealkit/mcp_data/` | TealKit tool schema JSONs |
| `tealkit/mcp_out/` | TealKit generated datasets |
| `weathersensorsmcp/mcp_data/` | Weather Sensors MCP tool schemas |
| `weathersensorsmcp/mcp_out/` | Weather Sensors MCP generated datasets |

### `py/` — Internal helpers (called by `train_mcp.sh`)

| File | Purpose |
|---|---|
| `py/download_hf_adapters.py` | Downloads LoRA adapter files from a HF repo |
| `py/detect_adapter_layout.py` | Prints `mlx`, `peft`, or `unknown` — routes fuse strategy |
| `py/merge_peft_adapter.py` | Merges PEFT/HF adapter into full base model via `merge_and_unload()` |
| `py/adapter_compatibility.py` | Checks adapter hidden size against base model config |
| `py/dataset_preflight.py` | Validates `train_split.jsonl` / `valid_split.jsonl` before training |
| `py/mlx_generate_test.py` | Quick MLX inference pass to validate fused model before GGUF |
| `py/mlx_output_check.py` | Checks MLX output for degeneration patterns |
| `py/patch_tokenizer_config.py` | Sets `fix_mistral_regex=True` in tokenizer_config (Mistral workaround) |
| `py/rewrite_tokenizer_fix.py` | Saves tokenizer with `fix_mistral_regex=True` applied |

### Notebooks

| File | Purpose |
|---|---|
| `tealkit_h100_optimized.ipynb` | **Primary Colab notebook** — H100-optimized, native GGUF export |
| `tealkit_training.ipynb` | Legacy T4 notebook (kept for reference) |

---

## Google Colab (H100 / Pro) — Training Notebook

> **This notebook (`tealkit_h100_optimized.ipynb`) is optimized for an H100 GPU
> on Colab Pro.** The H100's 80 GB VRAM eliminates the memory constraints that
> cause crashes during GGUF generation on free-tier T4 (12 GB). Key differences
> vs the old T4 notebook:
>
> | | H100 notebook | T4 / free tier |
> |---|---|---|
> | Base model precision | **bfloat16** (full 16-bit) | 4-bit quantised |
> | Batch size | **8** | 2 |
> | Gradient accumulation | 1 (none needed) | 4 |
> | Training epochs | **3** | 1 |
> | GGUF export | **native Unsloth** (no workaround) | requires T4 workaround or crashes |
>
> If you only have the free tier, train on T4 and export GGUF locally using
> `train_mcp.sh --download-hf-adapters your-repo --skip-train`.

### Before you start

1. Upload `train_split.jsonl` and `valid_split.jsonl` to Google Drive at:
   `MyDrive/Tealkit/training/mcp_data/`
2. Open the notebook in Colab Pro and select **Runtime → Change runtime type → H100 GPU**
3. The only cell you need to edit is **Cell 2**

### Workflow overview

| Cell | What it does |
|---|---|
| **Cell 1** | Install Unsloth — runtime restarts automatically; start from Cell 2 after restart |
| **Cell 2** | Config — edit `MODEL_NAME`, `DATA_DIR`, `OUTPUT_DIR`, `HF_REPO` here only |
| **Cell 3** | Mount Google Drive and verify `train_split.jsonl` + `valid_split.jsonl` |
| **Cell 4** | Load model in native **bfloat16** (H100 advantage: no 4-bit quantisation) |
| **Cell 5** | Apply LoRA adapters (`r=16`, standard Phi-4 / Qwen target modules) |
| **Cell 6** | Load dataset with anti-hallucination system prompt; apply chat template |
| **Cell 7** | H100-optimized training loop (batch 8, 3 epochs, response-masking) |
| **Cell 8** | Save adapters to Drive + **native GGUF export** via `save_pretrained_gguf` |

---

**Cell 1 — Install Unsloth**

> Run once. The runtime restarts automatically — do **not** re-run Cell 1.

```python
!pip install "unsloth[colab-new] @ git+https://github.com/unslothai/unsloth.git"
!pip install --no-deps "xformers<0.0.27" "trl<0.9.0" peft accelerate bitsandbytes datasets huggingface_hub
print('Install done. Restarting runtime...')
import IPython
IPython.Application.instance().kernel.do_shutdown(True)
```

---

**Cell 2 — ⚙️ Config (the only cell you need to edit)**

```python
# H100: use the full unquantised model (80 GB VRAM available)
MODEL_NAME = 'unsloth/Phi-4-mini-instruct'   # change to your preferred preset

# Your Google Drive paths
DATA_DIR   = '/content/drive/MyDrive/Tealkit/training/mcp_data'
OUTPUT_DIR = '/content/drive/MyDrive/Tealkit/training/mcp_adapters'

# Training settings
MAX_SEQ_LENGTH = 4096  # H100 can handle longer sequences

TRAIN_FILE = f'{DATA_DIR}/train_split.jsonl'
VALID_FILE = f'{DATA_DIR}/valid_split.jsonl'

# Your Hugging Face repo for upload (Cell 8 / push step)
HF_REPO = 'your-username/phi4mini-tealkit'

print('Model        :', MODEL_NAME)
print('Train file   :', TRAIN_FILE)
print('Valid file   :', VALID_FILE)
print('Adapters out :', OUTPUT_DIR)
print('HF repo      :', HF_REPO)
```

---

**Cell 3 — Mount Drive + verify paths**

```python
from google.colab import drive
import os

drive.mount('/content/drive', force_remount=True)

for _path, _label in [(TRAIN_FILE, 'train_split.jsonl'), (VALID_FILE, 'valid_split.jsonl')]:
    if not os.path.isfile(_path):
        print(f'MISSING {_label}: {_path}')
        print('  → Fix DATA_DIR in Cell 2 or upload files to Drive first.')
    else:
        _lines = sum(1 for _ in open(_path))
        print(f'OK  {_label}  ({_lines} rows)  {_path}')
```

---

**Cell 4 — Load model (native bfloat16)**

> H100 upgrade: `load_in_4bit=False` + `dtype=torch.bfloat16` loads the full
> precision model — no quantisation artifacts, and the H100 handles the memory
> comfortably.

```python
from unsloth import FastLanguageModel
import torch

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name=MODEL_NAME,
    max_seq_length=MAX_SEQ_LENGTH,
    load_in_4bit=False,       # H100: full 16-bit LoRA for better reasoning
    dtype=torch.bfloat16,     # H100: native bfloat16 acceleration
)
print('Model loaded in native bfloat16 precision.')
```

---

**Cell 5 — Apply LoRA adapters**

```python
model = FastLanguageModel.get_peft_model(
    model,
    r=16,
    target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj',
                    'gate_proj', 'up_proj', 'down_proj'],
    lora_alpha=16,
    lora_dropout=0,
    bias='none',
    use_gradient_checkpointing='unsloth',
    random_state=3407,
)
model.print_trainable_parameters()
```

---

**Cell 6 — Load dataset + anti-hallucination system prompt**

```python
from datasets import load_dataset

SYSTEM_PROMPT = (
    "You are a specialized TealKit MCP Agent with access to tools.\n"
    "CRITICAL INSTRUCTIONS:\n"
    "1. Do NOT call a tool for general greetings, casual conversation, or "
    "questions you can answer using your own knowledge.\n"
    "2. If a user request requires external data or an action covered by your "
    "tools, respond ONLY with the appropriate JSON tool call.\n"
    "3. If no tool is relevant, answer the user directly in plain text. "
    "Do not invent or hallucinate a tool call."
)

def format_example(examples):
    texts = []
    for msgs in examples['messages']:
        if not msgs or msgs[0].get('role') != 'system':
            msgs = [{'role': 'system', 'content': SYSTEM_PROMPT}] + list(msgs)
        texts.append(
            tokenizer.apply_chat_template(
                msgs, tokenize=False, add_generation_prompt=False
            )
        )
    return {'text': texts}

dataset = load_dataset('json', data_files={'train': TRAIN_FILE, 'validation': VALID_FILE})
dataset = dataset.map(format_example, batched=True)

print('Train examples:', len(dataset['train']))
print('Valid examples:', len(dataset['validation']))

# Phi-4 / ChatML native markers
INSTRUCTION_PART = '<|im_start|>user<|im_sep|>'
RESPONSE_PART    = '<|im_start|>assistant<|im_sep|>'
```

---

**Cell 7 — H100-optimized training loop**

> H100 upgrades: `per_device_train_batch_size=8` (vs 2 on T4),
> `gradient_accumulation_steps=1`, `num_train_epochs=3` for solid tool learning.

```python
from trl import SFTTrainer, SFTConfig
from transformers import DataCollatorForSeq2Seq
from unsloth.chat_templates import train_on_responses_only

_args = SFTConfig(
    per_device_train_batch_size=8,   # H100: larger batches
    gradient_accumulation_steps=1,   # H100: no accumulation needed
    warmup_steps=5,
    num_train_epochs=3,              # H100: more epochs for solid tool learning
    learning_rate=2e-4,
    logging_steps=5,
    eval_strategy='epoch',
    save_strategy='no',
    optim='adamw_8bit',
    weight_decay=0.01,
    lr_scheduler_type='linear',
    seed=3407,
    output_dir='/content/outputs',
    report_to='none',
)

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=dataset['train'],
    eval_dataset=dataset['validation'],
    dataset_text_field='text',
    max_seq_length=MAX_SEQ_LENGTH,
    data_collator=DataCollatorForSeq2Seq(tokenizer=tokenizer),
    packing=False,
    args=_args,
)

try:
    trainer = train_on_responses_only(
        trainer,
        instruction_part=INSTRUCTION_PART,
        response_part=RESPONSE_PART,
    )
    print(f'Response masking active: {len(trainer.train_dataset)} train samples.')
except Exception as e:
    print("WARNING: Response masking failed, using full sequence. Error:", e)

trainer.train()
model = trainer.model
print('Training complete.')
```

---

**Cell 8 — Save adapters + native GGUF export**

> Because we use 16-bit LoRA natively on the H100, `save_pretrained_gguf`
> works without the T4 OOM workarounds. The merge + GGUF export runs cleanly
> on H100 even for 3B–4B models.

```python
import os
if 'OUTPUT_DIR' not in dir(): OUTPUT_DIR = '/content/drive/MyDrive/Tealkit/training/mcp_adapters'
GGUF_DIR = '/content/merged_model_gguf'

# 1. Save LoRA adapters to Drive
os.makedirs(OUTPUT_DIR, exist_ok=True)
model.save_pretrained(OUTPUT_DIR)
tokenizer.save_pretrained(OUTPUT_DIR)
print('Adapters saved to Drive:', OUTPUT_DIR)

# 2. Native Unsloth GGUF export (H100 has enough RAM — no workaround needed)
print('\nMerging weights and exporting to Q4_K_M GGUF...')
model.save_pretrained_gguf(GGUF_DIR, tokenizer, quantization_method='q4_k_m')
print(f'\nGGUF export complete. Files in: {GGUF_DIR}')
```

### After Colab — using the GGUF locally

**Option A — GGUF already exported (Cell 8)**

Download from Google Drive and register in Ollama:

```bash
cat > /tmp/Modelfile <<'EOF'
FROM /path/to/your-model-q4_k_m.gguf
SYSTEM "You are a specialized MCP Agent. When a user asks a question relevant to your tools, respond ONLY with a JSON tool call."
EOF

ollama create phi4mini-tealkit -f /tmp/Modelfile
ollama run phi4mini-tealkit
```

Or push GGUF to Hugging Face from Colab, then pull:

```bash
ollama run hf.co/your-username/phi4mini-tealkit
```

**Option B — Only adapters saved (no GGUF)**

Download the adapter folder from HF and use `train_mcp.sh --skip-train` to fuse + convert locally:

```bash
bash scripts_training/train/train_mcp.sh --preset phi4 --skip-train \
  --download-hf-adapters your-username/phi4mini-tealkit \
  --hf-adapter-subdir adapters
```

---

## Practical Tips

- Keep validation strict. Bad JSONL silently reduces tool-call reliability.
- Add `no_tool` examples so the model learns to abstain when no tool matches.
- Track each dataset/model/adapter version pair — retrain produces different results.
- On mobile, set `num_ctx` explicitly in your Ollama Modelfile (e.g. `PARAMETER num_ctx 2048`) rather than relying on the default to control memory usage.
"""

out = pathlib.Path("/Users/laszloschaffer/projects/mobile_ai_agent/scripts_training/README.md")
out.write_text(README, encoding="utf-8")
print(f"Wrote {out} ({len(README)} chars, {README.count(chr(10))} lines)")
