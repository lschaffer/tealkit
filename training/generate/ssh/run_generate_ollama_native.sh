#!/usr/bin/env bash
set -euo pipefail

# Generate ssh training data for the ollama_native contract.
SERVER_SCOPE=ssh CONTRACT_TYPE=ollama_native exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
