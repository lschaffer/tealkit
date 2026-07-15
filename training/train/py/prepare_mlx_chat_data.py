#!/usr/bin/env python3
"""Prepare chat-format JSONL for MLX training by injecting a system prompt."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


DEFAULT_SYSTEM_PROMPT = (
    "You are a specialized MCP Agent with access to tools. "
    "When a user asks a question relevant to your tools, "
    "respond ONLY with a JSON tool call in this exact format: "
    "tool_call: {\"name\": \"<tool_name>\", \"arguments\": {...}}. "
    "Do not include any explanatory text. If no tool applies, respond naturally without tool_call prefix."
)


def load_system_prompt(system_prompt: str | None, system_prompt_file: Path | None) -> str:
    if system_prompt_file is not None:
        return system_prompt_file.read_text(encoding="utf-8").strip()
    if system_prompt is not None and system_prompt.strip():
        return system_prompt.strip()
    return DEFAULT_SYSTEM_PROMPT


def inject_system_prompt(input_path: Path, output_path: Path, system_prompt: str) -> tuple[int, int]:
    total = 0
    injected = 0
    output_lines: list[str] = []

    for line_number, raw_line in enumerate(input_path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped:
            continue

        try:
            row = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"{input_path}:{line_number}: invalid JSONL row: {exc}") from exc

        messages = row.get("messages")
        if not isinstance(messages, list):
            raise SystemExit(f"{input_path}:{line_number}: missing messages list")

        total += 1
        if not messages or not isinstance(messages[0], dict) or messages[0].get("role") != "system":
            row["messages"] = [{"role": "system", "content": system_prompt}] + list(messages)
            injected += 1

        output_lines.append(json.dumps(row, ensure_ascii=False))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(output_lines) + ("\n" if output_lines else ""), encoding="utf-8")
    return total, injected


def main() -> None:
    parser = argparse.ArgumentParser(description="Inject a missing system prompt into chat JSONL rows")
    parser.add_argument("--input", required=True, help="Input JSONL path")
    parser.add_argument("--output", required=True, help="Output JSONL path")
    parser.add_argument("--system-prompt", default=None, help="Inline system prompt text to inject")
    parser.add_argument("--system-prompt-file", default=None, help="File containing the system prompt to inject")
    args = parser.parse_args()

    system_prompt = load_system_prompt(
        args.system_prompt,
        Path(args.system_prompt_file) if args.system_prompt_file else None,
    )
    total, injected = inject_system_prompt(Path(args.input), Path(args.output), system_prompt)
    print(f"Prepared {total} rows -> {args.output} (injected system prompt into {injected})")


if __name__ == "__main__":
    main()