#!/usr/bin/env bash
set -euo pipefail

# Generate git training data for the ollama_native contract.
SERVER_SCOPE=git CONTRACT_TYPE=ollama_native exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
