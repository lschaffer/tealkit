# Download Models from HuggingFace

Helper scripts to download and register fine-tuned models from HuggingFace to Ollama.

## Why These Scripts?

When downloading models from HuggingFace, you need **both** the GGUF file and the `Modelfile` for tool support:

- **GGUF file** → The actual model weights (quantized)
- **Modelfile** → Contains the TEMPLATE directive that enables tool calling

❌ **Common mistake:** Downloading only the GGUF and registering with `FROM ./model.gguf`  
✅ **Correct approach:** Download both files and register with the Modelfile

These scripts automate the correct workflow.

---

## Quick Start

### Windows (PowerShell)

```powershell
# Download and register Qwen2.5-3B model
.\download-hf-model.ps1 -Repo "username/qwen2.5-3b-weathersensorsmcp"

# Download and register Ministral-3B model
.\download-hf-model.ps1 -Repo "username/ministral-3b-weathersensorsmcp"

# Use a different quantization (F16 instead of Q5)
.\download-hf-model.ps1 -Repo "username/qwen2.5-3b-weathersensorsmcp" -GgufPattern "*f16.gguf"

# Override the local model name
.\download-hf-model.ps1 -Repo "username/qwen2.5-3b-weathersensorsmcp" -ModelName "my-qwen-model"
```

### Mac/Linux (Bash)

```bash
# Make executable
chmod +x download-hf-model.sh

# Download and register Qwen2.5-3B model
./download-hf-model.sh username/qwen2.5-3b-weathersensorsmcp

# Download and register Ministral-3B model  
./download-hf-model.sh username/ministral-3b-weathersensorsmcp

# Use a different quantization (F16 instead of Q5)
./download-hf-model.sh username/qwen2.5-3b-weathersensorsmcp "" "*f16.gguf"

# Override the local model name
./download-hf-model.sh username/qwen2.5-3b-weathersensorsmcp my-qwen-model
```

---

## What the Scripts Do

1. **Fetch file list** from HuggingFace repository
2. **Find GGUF file** matching the pattern (default: `*q5_k_m.gguf`)
3. **Verify Modelfile exists** in the repository
4. **Download GGUF** to `./hf_models/<repo-name>/`
5. **Download Modelfile** to the same directory
6. **Register with Ollama** using the Modelfile (enables tool support)

---

## Output Structure

```
hf_models/
├── qwen2.5-3b-weathersensorsmcp/
│   ├── qwen2.5-3b-weathersensorsmcp-q5_k_m.gguf
│   └── Modelfile
└── ministral-3b-weathersensorsmcp/
    ├── ministral-3b-weathersensorsmcp-q5_k_m.gguf
    └── Modelfile
```

---

## Parameters

### PowerShell Script (`download-hf-model.ps1`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Repo` | ✅ Yes | - | HuggingFace repository (e.g., `username/model-name`) |
| `-ModelName` | ❌ No | Repository basename | Local Ollama model name |
| `-OutputDir` | ❌ No | `./hf_models/<repo>` | Download directory |
| `-GgufPattern` | ❌ No | `*q5_k_m.gguf` | GGUF filename pattern |

### Bash Script (`download-hf-model.sh`)

| Position | Required | Default | Description |
|----------|----------|---------|-------------|
| 1 | ✅ Yes | - | HuggingFace repository (e.g., `username/model-name`) |
| 2 | ❌ No | Repository basename | Local Ollama model name |
| 3 | ❌ No | `*q5_k_m.gguf` | GGUF filename pattern |

---

## Example: Qwen2.5-3B

```powershell
# Windows
.\download-hf-model.ps1 -Repo "lschaffer/qwen2.5-3b-weathersensorsmcp"

# Mac/Linux
./download-hf-model.sh lschaffer/qwen2.5-3b-weathersensorsmcp
```

**Output:**
```
═══════════════════════════════════════════════════════════
  Download & Register HuggingFace Model to Ollama
═══════════════════════════════════════════════════════════

Repository    : lschaffer/qwen2.5-3b-weathersensorsmcp
Model name    : qwen2.5-3b-weathersensorsmcp
Output dir    : ./hf_models/qwen2.5-3b-weathersensorsmcp
GGUF pattern  : *q5_k_m.gguf

[1/5] Fetching file list from HuggingFace...
✓ Found GGUF: qwen2.5-3b-weathersensorsmcp-q5_k_m.gguf
✓ Found Modelfile

[2/5] Creating output directory...
✓ Directory: ./hf_models/qwen2.5-3b-weathersensorsmcp

[3/5] Downloading GGUF (this may take several minutes)...
✓ Downloaded: ./hf_models/qwen2.5-3b-weathersensorsmcp/qwen2.5-3b-weathersensorsmcp-q5_k_m.gguf

[4/5] Downloading Modelfile...
✓ Downloaded: ./hf_models/qwen2.5-3b-weathersensorsmcp/Modelfile

[5/5] Registering model with Ollama...
  Running: ollama create qwen2.5-3b-weathersensorsmcp -f Modelfile
✓ Model registered: qwen2.5-3b-weathersensorsmcp

═══════════════════════════════════════════════════════════
  ✓ SUCCESS
═══════════════════════════════════════════════════════════

Model downloaded to: ./hf_models/qwen2.5-3b-weathersensorsmcp
Model registered as: qwen2.5-3b-weathersensorsmcp

To use the model:
  ollama run qwen2.5-3b-weathersensorsmcp

To test tool support:
  ollama run qwen2.5-3b-weathersensorsmcp 'What tools do you have?'
```

---

## Example: Ministral-3B

```powershell
# Windows
.\download-hf-model.ps1 -Repo "lschaffer/ministral-3b-weathersensorsmcp"

# Mac/Linux
./download-hf-model.sh lschaffer/ministral-3b-weathersensorsmcp
```

---

## Quantization Options

Different quantizations offer trade-offs between size and quality:

| Pattern | File Size | Quality | Use Case |
|---------|-----------|---------|----------|
| `*q5_k_m.gguf` | ~2.3 GB | High (recommended) | Best balance |
| `*q4_k_m.gguf` | ~1.9 GB | Good | Smaller, faster |
| `*f16.gguf` | ~6.7 GB | Maximum | Full precision |

**Example:** Download F16 quantization
```powershell
# Windows
.\download-hf-model.ps1 -Repo "username/model-name" -GgufPattern "*f16.gguf"

# Mac/Linux
./download-hf-model.sh username/model-name "" "*f16.gguf"
```

---

## Troubleshooting

### "✗ Ollama is not available"

Install Ollama first: https://ollama.com/download

### "✗ No GGUF file matching pattern"

The repository might not have that quantization. List available files:
```bash
curl -s https://huggingface.co/api/models/USERNAME/REPO/tree/main | jq -r '.[].path'
```

### "✗ Modelfile not found in repository"

The repository needs to be uploaded with the training script that includes `--upload-hf`.  
Older models may not have the Modelfile. You'll need to create one manually based on the model architecture.

### "does not support tools" Error

This happens when:
1. You downloaded only the GGUF (missing Modelfile) ❌
2. You registered with `FROM ./model.gguf` instead of using the Modelfile ❌

**Solution:** Re-run the script to download both files and register properly. ✅

---

## Manual Alternative

If you prefer to download manually:

```bash
# 1. Download both files
curl -L -o model.gguf https://huggingface.co/USERNAME/REPO/resolve/main/model-q5_k_m.gguf
curl -L -o Modelfile https://huggingface.co/USERNAME/REPO/resolve/main/Modelfile

# 2. Register with Ollama (TEMPLATE from Modelfile enables tools)
ollama create model-name -f Modelfile

# 3. Run
ollama run model-name
```

---

## See Also

- [Training Guide](../docs/) - How to train your own models
- [Mac Training Script](train/train_mcp.sh) - Full training pipeline for Mac
- [Colab Notebooks](notebooks/) - Training on Google Colab GPU
