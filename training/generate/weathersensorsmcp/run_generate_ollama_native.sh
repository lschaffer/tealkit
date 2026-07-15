#!/usr/bin/env bash
set -euo pipefail

CONTRACT_TYPE=ollama_native exec bash "$(dirname "$0")/run_generate_contract.sh"
