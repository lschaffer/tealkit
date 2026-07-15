#!/usr/bin/env bash
set -euo pipefail

# Generate ssh training data for the default text_tool_call contract.
SERVER_SCOPE=ssh CONTRACT_TYPE=text_tool_call exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
