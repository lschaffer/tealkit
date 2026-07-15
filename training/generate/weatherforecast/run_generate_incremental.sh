#!/usr/bin/env bash
set -euo pipefail

# Generate weatherforecast training data (text_tool_call) in incremental mode.
SERVER_SCOPE=weatherforecast CONTRACT_TYPE=text_tool_call INCREMENTAL=1 exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
