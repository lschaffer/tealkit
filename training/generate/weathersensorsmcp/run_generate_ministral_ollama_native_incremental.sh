#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible incremental entrypoint for the ollama_native weather dataset path, exporting to a separate Ministral-specific outputs folder.
CONTRACT_TYPE=ollama_native INCREMENTAL=1 OUTPUT_DIR_OVERRIDE="scripts_training/weathersensorsmcp/mcp_out_ministral" exec bash "$(dirname "$0")/run_generate_contract.sh"
