# Colab Notebook Changes

This document explains the notebook-side changes required by the two-contract refactor.

## Status

The training pipeline is now contract-aware in the shell and Python layers.

The physical notebook layout in the repo is now:
- `scripts_training/notebooks/text_tool_call/weathersensorsmcp_qwen_train.ipynb`
- `scripts_training/notebooks/text_tool_call/weathersensorsmcp_ministral_train.ipynb`
- `scripts_training/notebooks/ollama_native/weathersensorsmcp_qwen_train.ipynb`
- `scripts_training/notebooks/ollama_native/weathersensorsmcp_ministral_train.ipynb`

That means the notebook family split is now physical as well as logical.

## What Changed Conceptually

Before the refactor, the notebooks were effectively tied to one dataset contract:
- weather dataset paths were hardcoded
- prompt files were hardcoded
- quality-gate assumptions were hardcoded for text `tool_call:` output
- model naming did not distinguish native Ollama variants

After the refactor, notebooks should align with the same three axes as the shell pipeline:
- `server_scope`
- `contract_type`
- `model_preset`

## Notebook Mapping

Old logical notebook roles:
- `weathersensorsmcp_train.ipynb` for the Qwen text path
- `weathersensorsmcp_ministral_train.ipynb` for the Ministral text path

New logical notebook roles:
- `text_tool_call/weathersensorsmcp_qwen_train.ipynb`
- `text_tool_call/weathersensorsmcp_ministral_train.ipynb`
- `ollama_native/weathersensorsmcp_qwen_train.ipynb`
- `ollama_native/weathersensorsmcp_ministral_train.ipynb`

## What Should Change Inside the Notebooks

### 1. Setup cell

The setup cell should define contract-aware variables instead of only model-specific variables.

Recommended variables:
- `SERVER_SCOPE = "weathersensorsmcp"`
- `CONTRACT_TYPE = "text_tool_call"` or `"ollama_native"`
- `MODEL_PRESET = "qwen2_5_3b"`, `"qwen3_4b"`, or `"ministral_3b"`
- `CONTRACT_CONFIG` pointing at the matching config JSON under `scripts_training/servers/weathersensorsmcp/configs/...`

### 2. Dataset input cell

The dataset-input cell should stop hardcoding:
- `scripts_training/weathersensorsmcp/mcp_out/`
- `scripts_training/weathersensorsmcp/mcp_out_ministral/`
- legacy prompt paths embedded directly in notebook code

Instead, the notebook should read the contract config and derive:
- dataset directory
- prompt contract file
- quality-gate profile file
- model-name suffix rules

### 3. Prompt / contract cell

The text notebook family should keep teaching the strict text contract:
- assistant output starts with `tool_call: `
- payload keys are exactly `name` and `arguments`

The native notebook family must not reuse that target format as the desired final behavior.
Instead, it should point to the native prompt contract scaffold and native evaluation expectations.

### 4. Model naming cell

Notebook output names should now follow the shared naming rules:
- text models keep existing names such as `qwen2.5-3b-weathersensorsmcp`
- native models add the suffix, for example `qwen2.5-3b-weathersensorsmcp-ollama`

### 5. Export and upload cell

The export/upload cell should keep the same broad behavior, but the target repo and artifact names must respect the contract-specific model name.
That is the main user-visible difference after training.

### 6. Quality-gate cell

The validation cell should no longer assume a single built-in probe profile.
It should use the contract-specific profile file:
- `contracts/text_tool_call/quality_gate_profile.json`
- `contracts/ollama_native/quality_gate_profile.json`

## What Does Not Change

These parts of the notebooks remain conceptually the same:
- Colab runtime setup
- Drive mounting and package install flow
- train / valid dataset upload or copy steps
- LoRA training loop structure
- adapter save / merge / export stages
- pushing final artifacts to Hugging Face

## Qwen Notebook Notes

For the Qwen notebook family:
- keep ChatML-compatible training and export settings
- keep the text-contract path as the default first notebook to run
- use the new config-driven dataset and profile resolution rather than notebook-local hardcoded paths

## Ministral Notebook Notes

For the Ministral notebook family:
- keep the Mistral-format training assumptions
- keep model-family-specific template handling
- move dataset selection and naming to the shared contract config model
- treat the old separate `mcp_out_ministral` dataset location as legacy compatibility only

## Recommended Migration Order

1. Keep the `text_tool_call/` notebooks as the stable Colab baseline.
2. Replace notebook-local hardcoded paths with config-derived values over time.
3. Keep `ollama_native/` notebooks aligned structurally with the text notebooks.
4. Change only the contract-specific cells in the native notebooks.
5. Tighten the native evaluator once the final runtime contract is frozen.

## Practical Interpretation For Now

If you are training on Mac first, do not start with the notebook path.
Start with:
- `bootstrap_venv_mac.sh`
- `generate/weathersensorsmcp/run_generate.sh`
- `train/train_mcp.sh --contract-type text_tool_call --preset qwen2_5_3b`

Use the notebook family mainly for the Colab/CUDA route and treat this document as the migration guide for bringing the notebook layer into alignment with the refactored shell and Python pipeline.
