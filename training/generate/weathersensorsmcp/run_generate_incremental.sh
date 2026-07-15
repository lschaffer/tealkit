#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible incremental entrypoint for the text tool-call weather dataset path.
INCREMENTAL=1 exec bash "$(dirname "$0")/run_generate_contract.sh"
