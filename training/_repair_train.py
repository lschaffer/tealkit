#!/usr/bin/env python3
"""Standalone repair script - adds QG exemplar repeats to train.jsonl."""
import sys
import pathlib

script_dir = pathlib.Path(__file__).parent
sys.path.insert(0, str(script_dir))

from training_data_augment import prepare_training_lines

train_path = script_dir / "weathersensorsmcp/mcp_out/train.jsonl"
raw_lines = [l.strip() for l in train_path.read_text(encoding="utf-8").splitlines() if l.strip()]

print(f"Input: {len(raw_lines)} lines")
out_lines, stats = prepare_training_lines(raw_lines, target_total=None, followup_ratio=0.1)
print(f"Output: {len(out_lines)} lines")
print(f"Stats: {stats}")

# Count QG exemplar appearances
from training_data_augment import _quality_gate_exemplar_lines
from collections import Counter
qg = _quality_gate_exemplar_lines()
c = Counter(out_lines)
for i, qline in enumerate(qg):
    print(f"  QG{i+1} count: {c[qline]}")

train_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
print(f"Written: {train_path}")
print("OK")
