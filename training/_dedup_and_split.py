#!/usr/bin/env python3
"""One-shot: deduplicate train.jsonl and rebuild train_split / valid_split."""
import random
from pathlib import Path

MCP = Path(__file__).parent / "weathersensorsmcp" / "mcp_out"
SRC = MCP / "train.jsonl"
TRAIN_OUT = MCP / "train_split.jsonl"
VALID_OUT = MCP / "valid_split.jsonl"
VALID_RATIO = 0.05
SEED = 42

raw = [l.rstrip("\n") for l in SRC.read_text(encoding="utf-8").splitlines() if l.strip()]
seen: set = set()
deduped = []
for line in raw:
    if line not in seen:
        seen.add(line)
        deduped.append(line)

removed = len(raw) - len(deduped)
print(f"Source lines : {len(raw)}")
print(f"After dedup  : {len(deduped)}  (removed {removed} duplicates)")

rng = random.Random(SEED)
rng.shuffle(deduped)

n_valid = max(1, int(len(deduped) * VALID_RATIO))
valid_lines = deduped[:n_valid]
train_lines = deduped[n_valid:]

TRAIN_OUT.write_text("\n".join(train_lines) + "\n", encoding="utf-8")
VALID_OUT.write_text("\n".join(valid_lines) + "\n", encoding="utf-8")

print(f"train_split  : {len(train_lines)} lines -> {TRAIN_OUT}")
print(f"valid_split  : {len(valid_lines)} lines -> {VALID_OUT}")
