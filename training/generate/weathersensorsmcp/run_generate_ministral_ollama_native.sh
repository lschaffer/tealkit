#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible entrypoint for the ollama_native weather dataset path, exporting to a separate Ministral-specific outputs folder.
CONTRACT_TYPE=ollama_native OUTPUT_DIR_OVERRIDE="scripts_training/weathersensorsmcp/mcp_out_ministral" exec bash "$(dirname "$0")/run_generate_contract.sh"
