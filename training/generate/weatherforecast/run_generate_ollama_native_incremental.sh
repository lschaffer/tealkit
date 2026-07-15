#!/usr/bin/env bash
set -euo pipefail

# Generate weatherforecast training data (ollama_native) in incremental mode.
SERVER_SCOPE=weatherforecast CONTRACT_TYPE=ollama_native INCREMENTAL=1 exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
