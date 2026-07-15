#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible entrypoint for the text tool-call weather dataset path.
exec bash "$(dirname "$0")/run_generate_contract.sh"
