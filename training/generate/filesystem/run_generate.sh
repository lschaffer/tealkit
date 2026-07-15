#!/usr/bin/env bash
set -euo pipefail

# Generate filesystem training data for the default text_tool_call contract.
SERVER_SCOPE=filesystem CONTRACT_TYPE=text_tool_call exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
