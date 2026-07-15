#!/usr/bin/env python3
"""Compatibility wrapper for the shared quality gate core."""

from __future__ import annotations

import sys
from pathlib import Path


SCRIPT_FILE = Path(__file__).resolve()
SCRIPTS_TRAINING_ROOT = SCRIPT_FILE.parents[2]
if str(SCRIPTS_TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_TRAINING_ROOT))

from common.py.quality_gate.quality_gate_core import main


if __name__ == "__main__":
    main()
