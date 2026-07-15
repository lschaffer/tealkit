# scripts_training TODO

## Goals

- Build MCP fine-tuning data from weathersensorsmcp/mcp_data
- Validate JSONL quality before training
- Prepare dataset splits for LoRA training
- Document how to adapt an embedded model and publish GGUF to Hugging Face

## Steps

- [ ] Export latest tools schema
  - dart run scripts_training/export_mcp_tools.dart

- [ ] Create prompt for LLM data generation
  - python scripts_training/train.py --build-prompt
  - Output: scripts_training/weathersensorsmcp/mcp_out/generated_train_prompt.md

- [ ] Generate training data with your preferred LLM
  - Use scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md and scripts_training/weathersensorsmcp/train_prompt.md
  - Save raw output to:
    - scripts_training/weathersensorsmcp/mcp_out/train.jsonl (Qwen/Llama family)
    - scripts_training/weathersensorsmcp/mcp_out_ministral/train.jsonl (Ministral family)

- [ ] Validate generated JSONL
  - python scripts_training/validate_jsonl.py --jsonl scripts_training/weathersensorsmcp/mcp_out/train.jsonl --tools scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
  - or
  - python scripts_training/train.py --validate --jsonl scripts_training/weathersensorsmcp/mcp_out/train.jsonl --tools scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl

- [ ] Split train/valid datasets
  - python scripts_training/train.py --split --jsonl scripts_training/weathersensorsmcp/mcp_out/train.jsonl --valid-ratio 0.05

- [ ] Run LoRA pipeline
  - bash scripts_training/train_mcp.sh

## Python Environment

- Create venv
  - python -m venv scripts_training/.venv

- macOS recovery when venv creation fails at ensurepip but .venv exists
  - bash scripts_training/bootstrap_venv_mac.sh

- Activate on PowerShell
  - scripts_training/.venv/Scripts/Activate.ps1

- Optional pip upgrade
  - python -m pip install --upgrade pip

## Embedded model test: qwen3.x -> embedded instruct

- Pick a Qwen base that supports instruction tuning and tool-like formatting.
- Fine-tune with your MCP JSONL (LoRA/QLoRA).
- Export to GGUF (q4_k_m or q5_k_m first for device tests).
- Add a system prompt in runtime that enforces the tool_call format.
- Validate on held-out MCP tasks before shipping.

## Can I upload new GGUF to Hugging Face?

Yes.

Recommended flow:

1. Create or use a Hugging Face model repo
  - hf repo create <org_or_user>/<model-name> --type model

2. Login
  - hf auth login

3. Upload GGUF + metadata
  - hf upload <org_or_user>/<model-name> path/to/model.gguf model.gguf
   - Include README.md model card with:
     - base model
     - dataset source
     - training method (LoRA/QLoRA)
     - quantization method
     - evaluation results and limitations
     - intended use and safety notes

4. Optional large file strategy
   - Install git-lfs and push repo with LFS if uploading many checkpoints.

5. License check
   - Ensure the base model license allows redistribution of derived weights/quantized variants.
