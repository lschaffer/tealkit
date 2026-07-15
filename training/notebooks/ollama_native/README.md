# ollama_native notebooks

This folder is the target home for Colab notebooks that train the native Ollama tool-calling contract.

Current scaffold notebooks:
- `weathersensorsmcp_qwen_train.ipynb`
- `weathersensorsmcp_ministral_train.ipynb`

These notebooks now exist as runnable native-contract notebooks. The shell/config scaffolding exists, the training/export flow is executable, and the quality gate now evaluates native Ollama tool-call behavior instead of only the legacy text wrapper.

What is already present:
- native contract config setup cells
- Drive dataset checks for the `ollama_native` dataset path
- model-family-specific base model and LoRA setup cells
- runnable training cells
- runnable export / GGUF cells
- model-card and optional HF-upload cells

What is still intentionally left unfinished:
- broader end-to-end tuning and regression coverage versus the stable text path
- end-to-end verified native Colab training run against the final runtime path

Use [../../COLAB_NOTEBOOK_CHANGES.md](../../COLAB_NOTEBOOK_CHANGES.md) for the contract split, migration order, and cell-level changes.
