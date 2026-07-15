#!/usr/bin/env python3
"""Shared dataset helper for MCP training data preparation."""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path


SCRIPT_FILE = Path(__file__).resolve()
SCRIPTS_TRAINING_ROOT = SCRIPT_FILE.parents[3]
if str(SCRIPTS_TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_TRAINING_ROOT))

from common.py.dataset.validate_jsonl import _load_tools_data, validate_jsonl


def build_prompt(template_path: Path, tools_path: Path, output_path: Path) -> None:
    template = template_path.read_text(encoding="utf-8")
    tools_json = _load_tools_data(str(tools_path))
    rendered = template + "\n\n## MCP Tools JSON\n" + json.dumps(tools_json, ensure_ascii=False, indent=2) + "\n"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8")
    print(f"Prompt written: {output_path}")


def split_jsonl(input_jsonl: Path, train_out: Path, valid_out: Path, valid_ratio: float, seed: int) -> None:
    raw_lines = [line.rstrip("\n") for line in input_jsonl.read_text(encoding="utf-8").splitlines() if line.strip()]

    seen: set[str] = set()
    lines: list[str] = []
    for line in raw_lines:
        if line not in seen:
            seen.add(line)
            lines.append(line)
    removed = len(raw_lines) - len(lines)
    if removed:
        print(f"Removed {removed} duplicate lines ({len(raw_lines)} -> {len(lines)})")

    if len(lines) < 10:
        raise ValueError("Need at least 10 non-empty JSONL lines to create a train/valid split")

    rng = random.Random(seed)
    rng.shuffle(lines)

    valid_count = max(1, int(len(lines) * valid_ratio))
    valid_lines = lines[:valid_count]
    train_lines = lines[valid_count:]

    train_out.parent.mkdir(parents=True, exist_ok=True)
    valid_out.parent.mkdir(parents=True, exist_ok=True)

    train_out.write_text("\n".join(train_lines) + "\n", encoding="utf-8")
    valid_out.write_text("\n".join(valid_lines) + "\n", encoding="utf-8")

    print(f"Train lines: {len(train_lines)} -> {train_out}")
    print(f"Valid lines: {len(valid_lines)} -> {valid_out}")


def main() -> None:
    parser = argparse.ArgumentParser(description="MCP training dataset helper")
    parser.add_argument("--base-name", default="weather_sensors", help="Dataset base name")
    parser.add_argument("--output-dir", default="scripts_training/mcp_data", help="Base output folder for generated files")
    parser.add_argument("--tools", default=None, help="Path to tools schema JSON or JSONL")
    parser.add_argument("--template", default="scripts_training/train.md", help="Prompt template path")
    parser.add_argument("--prompt-out", default=None, help="Rendered prompt output file")
    parser.add_argument("--jsonl", default=None, help="Training JSONL input file")
    parser.add_argument("--train-out", default=None, help="Train split output")
    parser.add_argument("--valid-out", default=None, help="Valid split output")
    parser.add_argument("--valid-ratio", type=float, default=0.05, help="Validation ratio (0.0-0.5)")
    parser.add_argument("--seed", type=int, default=42, help="Shuffle seed for deterministic split")
    parser.add_argument("--contract-type", default="text_tool_call", help="Contract type: text_tool_call or ollama_native")
    parser.add_argument("--build-prompt", action="store_true", help="Generate prompt with embedded tool schema")
    parser.add_argument("--validate", action="store_true", help="Validate JSONL against tools schema")
    parser.add_argument("--split", action="store_true", help="Split JSONL into train/valid files")
    args = parser.parse_args()

    base_dir = Path(args.output_dir)
    dataset_dir = base_dir / args.base_name

    tools = Path(args.tools) if args.tools else (base_dir / f"{args.base_name}_tools.jsonl")
    template = Path(args.template)
    prompt_out = Path(args.prompt_out) if args.prompt_out else (dataset_dir / "generated_train_prompt.md")
    jsonl = Path(args.jsonl) if args.jsonl else (dataset_dir / "train.jsonl")
    train_out = Path(args.train_out) if args.train_out else (dataset_dir / "train_split.jsonl")
    valid_out = Path(args.valid_out) if args.valid_out else (dataset_dir / "valid_split.jsonl")

    if not (args.build_prompt or args.validate or args.split):
        parser.error("Choose at least one action: --build-prompt, --validate, --split")

    if args.build_prompt:
        if not template.exists():
            raise FileNotFoundError(f"Template not found: {template}")
        if not tools.exists():
            raise FileNotFoundError(f"Tools file not found: {tools}")
        build_prompt(template, tools, prompt_out)

    if args.validate:
        valid, errors = validate_jsonl(str(jsonl), str(tools), contract_type=args.contract_type)
        print(f"Validation summary -> valid={valid}, errors={errors}")
        if errors > 0:
            raise SystemExit(1)

    if args.split:
        if not jsonl.exists():
            raise FileNotFoundError(f"JSONL file not found: {jsonl}")
        if not (0.0 < args.valid_ratio < 0.5):
            raise ValueError("--valid-ratio must be between 0.0 and 0.5")
        split_jsonl(jsonl, train_out, valid_out, args.valid_ratio, args.seed)


if __name__ == "__main__":
    main()
