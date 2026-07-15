#!/usr/bin/env python3
"""
Inject a system prompt into training JSONL data for Unsloth Studio / Colab training.

Takes JSONL files with user/assistant messages (no system role) and prepends
the system prompt as the first message in every conversation.

Usage:
    python inject_system_prompt.py \\
        --train-in servers/ssh/datasets/text_tool_call/train_split.jsonl \\
        --valid-in servers/ssh/datasets/text_tool_call/valid_split.jsonl \\
        --system-prompt servers/ssh/prompts/ssh_system_prompt.md \\
        --train-out servers/ssh/datasets/text_tool_call/train_split_with_system.jsonl \\
        --valid-out servers/ssh/datasets/text_tool_call/valid_split_with_system.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def inject_system_prompt(
    jsonl_in: str,
    jsonl_out: str,
    system_prompt: str,
) -> tuple[int, int]:
    """Inject system prompt into JSONL, output new file."""
    input_path = Path(jsonl_in)
    output_path = Path(jsonl_out)

    if not input_path.exists():
        print(f"ERROR: Input file not found: {input_path}")
        return 0, 0

    lines_in = 0
    lines_out = 0

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with input_path.open("r", encoding="utf-8") as f_in, \
         output_path.open("w", encoding="utf-8") as f_out:
        for line in f_in:
            line = line.strip()
            if not line:
                continue
            lines_in += 1

            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"WARNING: Skipping invalid JSON line: {exc}")
                continue

            messages = record.get("messages", [])
            if not isinstance(messages, list):
                print(f"WARNING: Skipping record without messages list")
                continue

            # Only inject if first message is not already system
            if messages and isinstance(messages[0], dict) and messages[0].get("role") == "system":
                # System prompt already present — write as-is
                f_out.write(line + "\n")
            else:
                # Prepend system message
                messages.insert(0, {
                    "role": "system",
                    "content": system_prompt,
                })
                record["messages"] = messages
                f_out.write(json.dumps(record, ensure_ascii=False) + "\n")

            lines_out += 1

    return lines_in, lines_out


def load_system_prompt(path: str) -> str:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"System prompt file not found: {p}")
    return p.read_text(encoding="utf-8").strip()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Inject system prompt into training JSONL for Unsloth Studio"
    )
    parser.add_argument("--train-in", required=True, help="Input train JSONL (no system prompt)")
    parser.add_argument("--valid-in", required=True, help="Input valid JSONL (no system prompt)")
    parser.add_argument("--system-prompt", required=True, help="System prompt markdown file")
    parser.add_argument("--train-out", required=True, help="Output train JSONL (with system prompt)")
    parser.add_argument("--valid-out", required=True, help="Output valid JSONL (with system prompt)")
    args = parser.parse_args()

    system_prompt = load_system_prompt(args.system_prompt)

    print(f"System prompt ({len(system_prompt)} chars): {args.system_prompt}")
    print(f"Injecting into train split...")
    train_in, train_out = inject_system_prompt(args.train_in, args.train_out, system_prompt)
    print(f"  Input:  {train_in} rows")
    print(f"  Output: {train_out} rows → {args.train_out}")

    print(f"Injecting into valid split...")
    valid_in, valid_out = inject_system_prompt(args.valid_in, args.valid_out, system_prompt)
    print(f"  Input:  {valid_in} rows")
    print(f"  Output: {valid_out} rows → {args.valid_out}")

    print("Done. Files ready for Unsloth Studio upload.")


if __name__ == "__main__":
    main()
