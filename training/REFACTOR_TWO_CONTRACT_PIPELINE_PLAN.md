# Two-Contract Training Pipeline Refactor Plan

## Goal

Refactor `scripts_training/` into a clean two-contract pipeline that supports both:

- `text_tool_call` for embedded / llama.cpp style models that emit plain text `tool_call: {...}`
- `ollama_native` for Ollama-oriented models trained for native tool calling

The current pipeline remains the baseline for `text_tool_call`. The refactor must avoid duplicated Python helpers, duplicated shell logic, and duplicated notebook structure.

## Core Design Principle

Separate the pipeline across three independent axes:

1. `server_scope`
2. `contract_type`
3. `model_preset`

That means the same training/export code can run with combinations such as:

- `server_scope=weathersensorsmcp`, `contract_type=text_tool_call`, `model_preset=qwen2_5_3b`
- `server_scope=weathersensorsmcp`, `contract_type=ollama_native`, `model_preset=ministral_3b`

This removes the need to duplicate training scripts per model family or per MCP server.

## Target Directory Layout

```text
scripts_training/
  common/
    py/
      dataset/
      export/
      quality_gate/
      prompts/
      utils/
    templates/
      modelfile/
      notebooks/
      prompts/
  contracts/
    text_tool_call/
      README.md
      prompt_contract.md
      quality_gate_profile.json
      notebooks/
      wrappers/
    ollama_native/
      README.md
      prompt_contract.md
      quality_gate_profile.json
      notebooks/
      wrappers/
  servers/
    weathersensorsmcp/
      schema/
      prompts/
      datasets/
        text_tool_call/
        ollama_native/
      outputs/
        text_tool_call/
        ollama_native/
      configs/
        text_tool_call/
        ollama_native/
  generate/
    run_generate.sh
  train/
    train_mcp.sh
    py/
  quality_gate/
    py/
    run_text_quality_gate.sh
    run_ollama_native_quality_gate.sh
  notebooks/
    text_tool_call/
    ollama_native/
  README.md
  REFACTOR_TWO_CONTRACT_PIPELINE_PLAN.md
```

## Naming Rules

### Contract names

Use exactly these names in paths and CLI flags:

- `text_tool_call`
- `ollama_native`

Do not mix with older variants like `text_to_call`.

### Model names

Add the contract only for the new Ollama-native variants.

Examples:

- `qwen2.5-3b-weathersensorsmcp`
- `ministral-3b-weathersensorsmcp`
- `qwen2.5-3b-weathersensorsmcp-ollama`
- `ministral-3b-weathersensorsmcp-ollama`

This preserves compatibility for the current text path while making the new Ollama-oriented models explicit.

## Exact Current-to-Target Mapping

### Root docs and helpers

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/README.md` | `scripts_training/README.md` | Keep, update to describe the two-contract architecture |
| `scripts_training/train.md` | `scripts_training/contracts/text_tool_call/README.md` plus shared sections folded into root `README.md` | Split |
| `scripts_training/train_prompt.md` | `scripts_training/contracts/text_tool_call/prompt_contract.md` | Move and rename |
| `scripts_training/todo.md` | `scripts_training/todo.md` | Keep temporarily, later rewrite around the new structure |
| `scripts_training/README_DOWNLOAD_MODELS.md` | `scripts_training/README_DOWNLOAD_MODELS.md` | Keep, update examples for both model families |

### Server-specific assets

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/weathersensorsmcp/mcp_data/` | `scripts_training/servers/weathersensorsmcp/schema/` | Move |
| `scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md` | `scripts_training/servers/weathersensorsmcp/prompts/weather_sensors_system_prompt.md` | Completed server-scoped text prompt source of truth |
| `scripts_training/servers/weathersensorsmcp/prompts/ollama_native_system_prompt.md` | `scripts_training/servers/weathersensorsmcp/prompts/ollama_native_system_prompt.md` | Completed server-scoped native prompt source of truth |
| `scripts_training/weathersensorsmcp/train_prompt.md` | `scripts_training/contracts/text_tool_call/prompt_contract.md` plus server-specific prompt fragments under `scripts_training/servers/weathersensorsmcp/prompts/` | Split |
| `scripts_training/weathersensorsmcp/mcp_out/` | `scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/` | Move |
| `scripts_training/weathersensorsmcp/mcp_out_ministral/` | `scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/legacy_ministral/` during migration, then fold into unified contract dataset structure | Temporary migration bucket |
| `scripts_training/weathersensorsmcp/ministral_3b_gate_tmp/` | `scripts_training/servers/weathersensorsmcp/outputs/text_tool_call/ministral_3b_gate_tmp/` | Move |

### Dataset generation wrappers

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/generate/run_generate.sh` | `scripts_training/generate/run_generate.sh` | Keep as compatibility wrapper |
| `scripts_training/generate/weathersensorsmcp/run_generate.sh` | `scripts_training/contracts/text_tool_call/wrappers/run_generate_weathersensorsmcp.sh` | Move |
| `scripts_training/generate/weathersensorsmcp/run_generate_incremental.sh` | `scripts_training/contracts/text_tool_call/wrappers/run_generate_weathersensorsmcp_incremental.sh` | Move |
| `scripts_training/generate/weathersensorsmcp/run_generate_ministral.sh` | Remove after config unification | Replace with `--model-preset ministral_3b` |
| `scripts_training/generate/weathersensorsmcp/run_generate_ministral_incremental.sh` | Remove after config unification | Replace with `--model-preset ministral_3b --incremental` |

### Shared generation Python

Move these into `scripts_training/common/py/dataset/` unless noted otherwise.

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/generate/py/generate_starter_jsonl.py` | `scripts_training/common/py/dataset/generate_starter_jsonl.py` | Move |
| `scripts_training/generate/py/generate_train_jsonl_gemini.py` | `scripts_training/common/py/dataset/generate_train_jsonl_gemini.py` | Move |
| `scripts_training/generate/py/generate_train_jsonl_gemini_incremental.py` | `scripts_training/common/py/dataset/generate_train_jsonl_gemini_incremental.py` | Move |
| `scripts_training/generate/py/train.py` | `scripts_training/common/py/dataset/train_dataset_cli.py` | Move and rename |
| `scripts_training/generate/py/training_data_augment.py` | `scripts_training/common/py/dataset/training_data_augment.py` | Move |
| `scripts_training/generate/py/validate_jsonl.py` | `scripts_training/common/py/dataset/validate_jsonl.py` | Move |

### Training pipeline shell and Python

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/train/train_mcp.sh` | `scripts_training/train/train_mcp.sh` | Keep as the main shared entrypoint, add `--contract-type` |
| `scripts_training/train/upload_gguf_to_tealkit.sh` | `scripts_training/train/upload_gguf_to_tealkit.sh` | Keep |
| `scripts_training/train/py/adapter_compatibility.py` | `scripts_training/common/py/utils/adapter_compatibility.py` | Move |
| `scripts_training/train/py/convert_to_csv.py` | `scripts_training/common/py/utils/convert_to_csv.py` | Move |
| `scripts_training/train/py/convert_to_csv_clean.py` | `scripts_training/common/py/utils/convert_to_csv_clean.py` | Move |
| `scripts_training/train/py/convert_to_hf_format.py` | `scripts_training/common/py/export/convert_to_hf_format.py` | Move |
| `scripts_training/train/py/convert_to_unsloth_native.py` | `scripts_training/common/py/export/convert_to_unsloth_native.py` | Move |
| `scripts_training/train/py/dataset_preflight.py` | `scripts_training/common/py/dataset/dataset_preflight.py` | Move |
| `scripts_training/train/py/detect_adapter_layout.py` | `scripts_training/common/py/utils/detect_adapter_layout.py` | Move |
| `scripts_training/train/py/download_hf_adapters.py` | `scripts_training/common/py/export/download_hf_adapters.py` | Move |
| `scripts_training/train/py/merge_peft_adapter.py` | `scripts_training/common/py/export/merge_peft_adapter.py` | Move |
| `scripts_training/train/py/mlx_generate_test.py` | `scripts_training/common/py/utils/mlx_generate_test.py` | Move |
| `scripts_training/train/py/mlx_output_check.py` | `scripts_training/common/py/utils/mlx_output_check.py` | Move |
| `scripts_training/train/py/patch_tokenizer_config.py` | `scripts_training/common/py/export/patch_tokenizer_config.py` | Move |
| `scripts_training/train/py/prepare_mlx_chat_data.py` | `scripts_training/common/py/dataset/prepare_mlx_chat_data.py` | Move |
| `scripts_training/train/py/rewrite_tokenizer_fix.py` | `scripts_training/common/py/export/rewrite_tokenizer_fix.py` | Move |
| `scripts_training/train/py/train_lora.py` | `scripts_training/train/py/train_lora.py` | Keep as training-specific core, but make it contract-aware via config |

### Quality gate

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/quality_gate/py/quality_gate.py` | `scripts_training/common/py/quality_gate/quality_gate_core.py` and a thin shim at the original path | Split |
| `scripts_training/quality_gate/run_qwen3_quality_gate.sh` | `scripts_training/contracts/text_tool_call/wrappers/run_qwen3_quality_gate.sh` | Move |
| `scripts_training/quality_gate/run_ministral_quality_gate.sh` | `scripts_training/contracts/text_tool_call/wrappers/run_ministral_quality_gate.sh` | Move |
| new | `scripts_training/quality_gate/run_text_quality_gate.sh` | Add |
| new | `scripts_training/quality_gate/run_ollama_native_quality_gate.sh` | Add |
| new | `scripts_training/contracts/text_tool_call/quality_gate_profile.json` | Add |
| new | `scripts_training/contracts/ollama_native/quality_gate_profile.json` | Add |

### Notebooks

| Current path | Target path | Action |
|---|---|---|
| `scripts_training/notebooks/weathersensorsmcp_train.ipynb` | `scripts_training/notebooks/text_tool_call/weathersensorsmcp_qwen_train.ipynb` | Move and rename |
| `scripts_training/notebooks/weathersensorsmcp_ministral_train.ipynb` | `scripts_training/notebooks/text_tool_call/weathersensorsmcp_ministral_train.ipynb` | Move |
| new | `scripts_training/notebooks/ollama_native/weathersensorsmcp_qwen_train.ipynb` | Add |
| new | `scripts_training/notebooks/ollama_native/weathersensorsmcp_ministral_train.ipynb` | Add |

## Common vs Contract-Specific Responsibilities

### Shared in `common`

Shared code must not hardcode:

- `weathersensorsmcp`
- `tool_call:` output text
- Qwen-only assumptions
- Ministral-only assumptions
- Ollama-native response parsing rules

Shared code may handle:

- JSONL validation framework
- train/valid splitting
- dataset preflight checks
- adapter detection
- HF upload helpers
- GGUF export helpers
- generic quality-gate runner framework
- notebook template fragments
- prompt assembly helpers

### Contract-specific in `contracts`

`text_tool_call` owns:

- canonical assistant target of `tool_call: {"name":"...","arguments":{...}}`
- prompt contract text
- text-based evaluation rules
- notebook cells and docs that teach or check the text contract

`ollama_native` owns:

- native-tool prompt contract
- native-tool evaluation rules
- Ollama-native quality gate profile
- notebook cells and docs that test native tool behavior

### Server-specific in `servers`

`servers/weathersensorsmcp` owns:

- tool schema
- production system prompt content
- server-specific prompt fragments
- generated datasets and outputs for both contracts
- server-specific config defaults

## Planned Config Model

Introduce a small config layer used by both shell and Python entrypoints.

Suggested config files:

- `scripts_training/servers/weathersensorsmcp/configs/text_tool_call/config.json`
- `scripts_training/servers/weathersensorsmcp/configs/ollama_native/config.json`

Each config should resolve:

- schema path
- prompt fragments
- dataset input and output directories
- quality gate profile
- default model name suffix
- preferred notebook family

The shell entrypoint should accept:

```bash
bash scripts_training/train/train_mcp.sh \
  --server-scope weathersensorsmcp \
  --contract-type text_tool_call \
  --preset qwen2_5_3b
```

and:

```bash
bash scripts_training/train/train_mcp.sh \
  --server-scope weathersensorsmcp \
  --contract-type ollama_native \
  --preset ministral_3b
```

## Dataset Plan

### `text_tool_call`

Keep the current dataset strategy as the baseline.

Target dataset location:

- `scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/`

Expected files:

- `train.jsonl`
- `train_split.jsonl`
- `valid_split.jsonl`
- `generated_train_prompt.md`
- optional intermediate generation logs

### `ollama_native`

Create a separate dataset directory.

Target dataset location:

- `scripts_training/servers/weathersensorsmcp/datasets/ollama_native/`

Expected files:

- `train.jsonl`
- `train_split.jsonl`
- `valid_split.jsonl`
- `generated_train_prompt.md`
- validation reports specific to the native contract

Important rule:

The Ollama-native dataset must not be created only by changing export scripts or Modelfiles. It needs contract-specific examples. Existing text-tool-call examples may be reused as source material for user prompts and expected tool selection, but the assistant target representation must be regenerated for the native contract.

## Notebook Plan

### Text family

Keep two notebooks under `scripts_training/notebooks/text_tool_call/`:

- `weathersensorsmcp_qwen_train.ipynb`
- `weathersensorsmcp_ministral_train.ipynb`

### Ollama-native family

Create parallel notebooks under `scripts_training/notebooks/ollama_native/`:

- `weathersensorsmcp_qwen_train.ipynb`
- `weathersensorsmcp_ministral_train.ipynb`

### Notebook reuse rules

Notebook structure should remain aligned across both contracts:

1. setup and installs
2. contract configuration
3. dataset load and validation
4. training
5. merge and GGUF export
6. Modelfile generation
7. Ollama registration
8. quality gate
9. HF upload

Only the following cells should differ by contract:

- contract selection/config cells
- prompt contract content
- dataset path cells
- quality gate cells
- model naming cells

## Quality Gate Split

The quality gate must be split by contract.

### Text contract gate

Success means:

- correct tool selection
- correct arguments
- accepted output shape is the existing text `tool_call:` format
- extra prose around tool calls fails when strict mode is enabled

### Ollama-native gate

Success means:

- request is sent through the Ollama-native tools path
- correct tool is selected
- correct arguments are selected
- native behavior is preferred over legacy text-tool-call emission

Failure examples for the native gate:

- model emits only legacy plain-text `tool_call:` output when native behavior was expected
- wrong tool chosen
- required arguments missing
- native tool call collapses into generic prose

## Compatibility Shims

To avoid breaking current commands, keep temporary compatibility wrappers for one migration cycle.

### Shell wrappers to keep temporarily

- `scripts_training/generate/run_generate.sh`
- `scripts_training/train/train_mcp.sh`
- `scripts_training/quality_gate/run_qwen3_quality_gate.sh`
- `scripts_training/quality_gate/run_ministral_quality_gate.sh`

### Shim behavior

Each shim should:

1. log that it is a compatibility wrapper
2. forward into the new contract-aware entrypoint
3. default to `contract_type=text_tool_call`
4. preserve existing model names and dataset locations when possible

### Shim removal rule

Remove wrappers only after:

- README examples are updated
- notebooks are migrated
- CI or manual checks use the new paths
- the old commands are no longer referenced in docs or videos

## Proposed Rollout Phases

### Phase 1: Freeze the baseline

- Declare the current pipeline as the baseline `text_tool_call` implementation
- Add this plan doc
- Do not change output behavior yet

### Phase 2: Extract shared code

- create `common/py/`
- move shared generation, dataset, export, and utility Python files
- keep import-compatible shims where needed

### Phase 3: Introduce contract config

- add `--contract-type` to `train_mcp.sh`
- add config files under `servers/weathersensorsmcp/configs/`
- make dataset, prompt, quality-gate, and model naming resolve from config

### Phase 4: Move the weather server assets

- create `servers/weathersensorsmcp/`
- move schema, prompts, datasets, and outputs
- retain thin wrappers for old paths until docs are updated

### Phase 5: Split the quality gate

- extract shared gate logic into `common/py/quality_gate/`
- keep a text contract gate matching current behavior
- add an Ollama-native gate and profile

### Phase 6: Add Ollama-native data path

- create prompt contract and generation wrappers for `ollama_native`
- generate a separate dataset folder
- validate the dataset independently

### Phase 7: Add Ollama-native notebooks

- create Qwen and Ministral native notebooks
- keep structure aligned with the text notebooks

### Phase 8: Clean up legacy names

- remove `mcp_out_ministral` once unified outputs are in place
- remove `run_generate_ministral*` wrapper duplication
- keep only server-scoped prompt sources under `scripts_training/servers/weathersensorsmcp/prompts/`

## First Implementation Slice

The safest first code slice after this plan is:

1. add `common/py/` and move only pure helpers there
2. keep all old entrypoints working via import or shell wrappers
3. add `contract_type=text_tool_call` as a no-op default in `train_mcp.sh`
4. create empty scaffolding for `contracts/ollama_native/` and `servers/weathersensorsmcp/configs/ollama_native/`
5. add the second quality-gate profile before changing any notebook or generation code

This sequence minimizes breakage and keeps the current text-tool-call training flow operational throughout the migration.

## Out of Scope for This First Refactor Step

These are not part of the initial structural refactor:

- redesigning the app-side Ollama runtime integration
- changing production app prompts
- deleting old Hugging Face model artifacts
- rewriting historical datasets in place
- guaranteeing that Ollama-native training format matches a final runtime contract before probe validation is defined

## Definition of Done for the Refactor

The refactor is complete when:

1. the current text-tool-call training flow still works through the new structure
2. shared Python helpers exist in one place only
3. weather-server assets live under `servers/weathersensorsmcp/`
4. a separate `ollama_native` dataset path exists
5. a separate `ollama_native` notebook family exists
6. text and native quality gates are independent
7. new model names clearly distinguish the Ollama-native variants
