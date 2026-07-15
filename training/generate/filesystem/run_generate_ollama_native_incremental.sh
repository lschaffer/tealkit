#!/usr/bin/env bash
set -euo pipefail

# Generate filesystem training data (ollama_native) in incremental mode.
SERVER_SCOPE=filesystem CONTRACT_TYPE=ollama_native INCREMENTAL=1 exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
