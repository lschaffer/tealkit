"""Debug script: verify QG exemplar repeat count after prepare_training_lines."""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from collections import Counter
from training_data_augment import prepare_training_lines, _quality_gate_exemplar_lines

qg = _quality_gate_exemplar_lines()
print("QG line 1 (first 80 chars):", qg[0][:80])

# Test 1: minimal input (just the 4 QG lines)
out, stats = prepare_training_lines(qg.copy(), target_total=None, followup_ratio=0.1)
c = Counter(out)
print(f"[TEST1] Total output lines: {len(out)}")
print(f"[TEST1] QG1 count: {c[qg[0]]}, QG2: {c[qg[1]]}, QG3: {c[qg[2]]}, QG4: {c[qg[3]]}")
print(f"[TEST1] stats: {stats}")

# Test 2: read actual train.jsonl and run through prepare_training_lines
train_path = pathlib.Path(__file__).parent / "weathersensorsmcp/mcp_out/train.jsonl"
raw_lines = [l.strip() for l in train_path.read_text(encoding="utf-8").splitlines() if l.strip()]
print(f"\n[TEST2] Input lines: {len(raw_lines)}")
out2, stats2 = prepare_training_lines(raw_lines, target_total=None, followup_ratio=0.1)
c2 = Counter(out2)
print(f"[TEST2] Total output lines: {len(out2)}")
print(f"[TEST2] QG1 count: {c2[qg[0]]}, QG2: {c2[qg[1]]}, QG3: {c2[qg[2]]}, QG4: {c2[qg[3]]}")
print(f"[TEST2] stats: {stats2}")

# Check if normalized QG lines match originals
import json
from training_data_augment import _normalize_row

for i, qline in enumerate(qg):
    normed, dropped = _normalize_row(qline)
    matches = (normed == qline)
    print(f"[NORM] QG{i+1}: round-trip match={matches}, dropped={dropped}")
    if not matches:
        print(f"  ORIGINAL: {qline[:100]}")
        print(f"  NORMED:   {normed[:100] if normed else 'None'}")
