#!/usr/bin/env bash
set -euo pipefail

# Generate git training data (ollama_native) in incremental mode.
SERVER_SCOPE=git CONTRACT_TYPE=ollama_native INCREMENTAL=1 exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
