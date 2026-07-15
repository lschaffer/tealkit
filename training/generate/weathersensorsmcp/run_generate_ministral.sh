#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible legacy separate-output entrypoint for the text tool-call weather dataset path.
OUTPUT_DIR_OVERRIDE="scripts_training/weathersensorsmcp/mcp_out_ministral" exec bash "$(dirname "$0")/run_generate_contract.sh"
