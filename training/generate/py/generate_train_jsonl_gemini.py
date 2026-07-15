#!/usr/bin/env python3
"""Generate MCP training JSONL with a configurable example-generator model and validate it.

Usage (macOS/Linux):
    export DEEPSEEK_API_KEY="your_key"
    scripts_training/.venv/bin/python scripts_training/generate_train_jsonl_gemini.py

Optional:
    scripts_training/.venv/bin/python scripts_training/generate_train_jsonl_gemini.py \
        --model deepseek-v4-pro \
        --count 360 \
        --prompt scripts_training/weathersensorsmcp/mcp_out/generated_train_prompt.md \
        --out scripts_training/weathersensorsmcp/mcp_out/train.jsonl \
        --tools scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_FILE = Path(__file__).resolve()
SCRIPTS_TRAINING_ROOT = SCRIPT_FILE.parents[2]
if str(SCRIPTS_TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_TRAINING_ROOT))

from common.py.dataset.gemini_generation_common import (
    OLLAMA_NATIVE_CONTRACT,
    generate_with_example_model,
    has_parseable_tool_call,
    normalize_training_row,
    row_has_schema_errors,
)
from training_data_augment import prepare_training_lines
from validate_jsonl import _load_tools_schema, _validate_tool_parameters, validate_jsonl


def _count_non_empty_lines(text: str) -> int:
    return sum(1 for line in text.splitlines() if line.strip())


def _non_empty_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]




def _dedupe_jsonl_lines(lines: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if line in seen:
            continue
        seen.add(line)
        out.append(line)
    return out


def _sanitize_jsonl_lines(text: str, tools_schema: dict[str, dict], contract_type: str) -> tuple[str, int, int]:
    """Keep only valid JSON-object lines; drop malformed tail lines.

    Returns: (sanitized_text, kept_count, dropped_count)
    """
    kept: list[str] = []
    dropped = 0

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
            if isinstance(parsed, dict):
                normalized = normalize_training_row(parsed, tools_schema, contract_type=contract_type)
                # Keep only rows with parseable and schema-valid tool calls.
                if has_parseable_tool_call(normalized, contract_type=contract_type) and not row_has_schema_errors(
                    normalized,
                    tools_schema,
                    _validate_tool_parameters,
                    contract_type=contract_type,
                ):
                    kept.append(json.dumps(normalized, ensure_ascii=False))
                else:
                    dropped += 1
            else:
                dropped += 1
        except json.JSONDecodeError:
            dropped += 1

    kept = _dedupe_jsonl_lines(kept)

    sanitized = "\n".join(kept)
    if sanitized:
        sanitized += "\n"
    return sanitized, len(kept), dropped


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate tool-calling JSONL via a configurable example-generator model and validate it")
    parser.add_argument("--prompt", default="scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/generated_train_prompt.md", help="Prompt markdown path")
    parser.add_argument("--out", default="scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/train.jsonl", help="Output JSONL path")
    parser.add_argument("--tools", default="scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl", help="Tool schema JSON or JSONL path")
    parser.add_argument("--model", default="deepseek-v4-pro", help="Example-generator model name")
    parser.add_argument("--count", type=int, default=360, help="Target number of examples to request (minimum 300)")
    parser.add_argument("--min-valid", type=int, default=300, help="Minimum required count of schema-valid examples")
    parser.add_argument("--attempts", type=int, default=3, help="Max generation attempts")
    parser.add_argument("--topup-chunk", type=int, default=220, help="Requested lines per top-up call when below min-valid")
    parser.add_argument("--topup-rounds", type=int, default=6, help="Max top-up rounds per attempt")
    parser.add_argument("--contract-type", default="text_tool_call", help="Contract type: text_tool_call or ollama_native")
    args = parser.parse_args()

    prompt_path = Path(args.prompt)
    out_path = Path(args.out)
    tools_path = Path(args.tools)

    if not prompt_path.exists():
        raise SystemExit(f"Prompt file not found: {prompt_path}")
    if not tools_path.exists():
        raise SystemExit(f"Tools file not found: {tools_path}")

    if args.count < 300:
        print("Requested --count is below 300; overriding to 300 for minimum dataset size.")
        args.count = 300

    if args.min_valid < 300:
        print("Requested --min-valid is below 300; overriding to 300.")
        args.min_valid = 300

    if args.topup_chunk < 50:
        print("Requested --topup-chunk is too low; overriding to 50.")
        args.topup_chunk = 50

    if args.topup_rounds < 1:
        print("Requested --topup-rounds is below 1; overriding to 1.")
        args.topup_rounds = 1

    base_prompt = prompt_path.read_text(encoding="utf-8")
    tools_schema = _load_tools_schema(str(tools_path))

    best_text = ""
    best_valid = -1
    best_errors = 10**9
    best_zero_error_text = ""
    best_zero_error_valid = -1

    for attempt in range(1, args.attempts + 1):
        print(f"Attempt {attempt}/{args.attempts}: generating with {args.model}...")

        prompt = (
            base_prompt
            + "\n\n"
            + f"Generate approximately {args.count} JSONL lines. "
            + "Return JSONL only. No markdown. No extra explanations."
        )
        if args.contract_type == OLLAMA_NATIVE_CONTRACT:
            prompt += (
                " Every assistant tool-calling message must use native Ollama structure with empty content and "
                "tool_calls=[{\"function\":{\"name\":\"<tool>\",\"arguments\":{...}}}]. "
                "Do not use the legacy tool_call: text wrapper."
            )

        text = generate_with_example_model(args.model, prompt, temperature=0.4, top_p=0.9)

        sanitized_text, kept_count, dropped_count = _sanitize_jsonl_lines(text, tools_schema, args.contract_type)

        line_count = _count_non_empty_lines(sanitized_text)
        print(f"Wrote {line_count} sanitized non-empty lines to {out_path}")
        if dropped_count > 0:
            print(f"Dropped {dropped_count} malformed lines (usually truncated tail output)")

        valid = line_count
        errors = 0

        # Optional chunked top-up when clean but below minimum valid target.
        if errors == 0 and valid < args.min_valid:
            merged_lines = _non_empty_lines(sanitized_text)
            missing = args.min_valid - valid
            print(f"Top-up generation needed: missing {missing} valid lines")

            for round_index in range(1, args.topup_rounds + 1):
                if valid >= args.min_valid or errors != 0:
                    break

                missing = args.min_valid - valid
                request_count = min(args.topup_chunk, missing)
                print(
                    f"Top-up round {round_index}/{args.topup_rounds}: "
                    f"requesting about {request_count} lines (missing {missing})"
                )

                topup_prompt = (
                    base_prompt
                    + "\n\n"
                    + f"Generate approximately {request_count} additional JSONL lines. "
                    + "Use mixed tools across the full schema. No markdown, JSONL only."
                )
                topup_text = generate_with_example_model(args.model, topup_prompt, temperature=0.4, top_p=0.9)
                topup_sanitized, _, topup_dropped = _sanitize_jsonl_lines(topup_text, tools_schema, args.contract_type)
                if topup_dropped > 0:
                    print(f"Dropped {topup_dropped} malformed lines in top-up round {round_index}")

                merged_lines = _dedupe_jsonl_lines(merged_lines + _non_empty_lines(topup_sanitized))
                sanitized_text = "\n".join(merged_lines) + ("\n" if merged_lines else "")
                valid = len(merged_lines)
                errors = 0
                print(f"Post top-up round {round_index}: sanitized lines={valid}, errors={errors}")

        prepared_lines, prep_stats = prepare_training_lines(
            _non_empty_lines(sanitized_text),
            target_total=args.count,
            followup_ratio=0.1,
            contract_type=args.contract_type,
            tools_schema=tools_schema,
        )
        prepared_text = "\n".join(prepared_lines) + ("\n" if prepared_lines else "")
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(prepared_text, encoding="utf-8")
        print(
            "Prepared dataset: "
            f"original={prep_stats['original_lines']} "
            f"followup={prep_stats['followup_lines']} "
            f"dropped_bad_no_tool={prep_stats['dropped_bad_no_tool']} "
            f"final={prep_stats['final_lines']}"
        )

        valid, errors = validate_jsonl(str(out_path), str(tools_path), contract_type=args.contract_type)
        print(f"Validation result: valid={valid}, errors={errors}")

        if valid > best_valid or (valid == best_valid and errors < best_errors):
            best_text = prepared_text
            best_valid = valid
            best_errors = errors

        if errors == 0 and valid > best_zero_error_valid:
            best_zero_error_text = prepared_text
            best_zero_error_valid = valid

        if errors == 0 and valid >= args.min_valid:
            print(f"Success: validation passed with zero errors and valid>={args.min_valid}.")
            return

    # Keep the best zero-error attempt on disk if available.
    if best_zero_error_text:
        out_path.write_text(best_zero_error_text.rstrip() + "\n", encoding="utf-8")
    elif best_text:
        out_path.write_text(best_text.rstrip() + "\n", encoding="utf-8")

    raise SystemExit(
        f"Generation finished but still invalid: best valid={best_valid}, errors={best_errors}, min_valid={args.min_valid}. "
        "Open the output file and run the validator to inspect line-level issues."
    )


if __name__ == "__main__":
    main()
