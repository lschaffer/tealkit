#!/usr/bin/env bash
set -euo pipefail

# Generate git training data (text_tool_call) in incremental mode.
SERVER_SCOPE=git CONTRACT_TYPE=text_tool_call INCREMENTAL=1 exec bash "$(dirname "$0")/../weathersensorsmcp/run_generate_contract.sh"
