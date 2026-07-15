#!/usr/bin/env python3
"""Incremental JSONL generation with explicit tool coverage.

This script generates training data in multiple passes, each pass focusing on a
subset of tools, then merges and validates the final JSONL.

Usage (PowerShell):
    $env:DEEPSEEK_API_KEY="your_key"
    scripts_training/.venv/Scripts/python.exe scripts_training/generate_train_jsonl_gemini_incremental.py

Optional:
    scripts_training/.venv/Scripts/python.exe scripts_training/generate_train_jsonl_gemini_incremental.py `
        --model deepseek-v4-pro `
        --total 360 `
        --tools-per-chunk 8 `
        --examples-per-chunk 40
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path
from typing import Iterable

SCRIPT_FILE = Path(__file__).resolve()
SCRIPTS_TRAINING_ROOT = SCRIPT_FILE.parents[2]
if str(SCRIPTS_TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_TRAINING_ROOT))

from common.py.dataset.gemini_generation_common import (
    OLLAMA_NATIVE_CONTRACT,
    extract_tool_payload,
    generate_with_example_model,
    has_parseable_tool_call,
    normalize_training_row,
    row_has_schema_errors,
    strip_markdown_fences,
)
from training_data_augment import prepare_training_lines
from validate_jsonl import _load_tools_data, _load_tools_schema, _validate_tool_parameters, validate_jsonl


def _non_empty_lines(text: str) -> list[str]:
    """Split text into JSONL lines, reassembling multi-line JSON objects.

    Gemini Flash frequently returns pretty-printed multi-line JSON objects
    instead of single-line JSONL.  This function uses bracket depth tracking
    to join those back into single lines before returning.
    """
    raw_lines = [line for line in text.splitlines() if line.strip()]
    result: list[str] = []
    buffer: list[str] = []
    depth = 0
    in_string = False
    escaped = False

    for line in raw_lines:
        buffer.append(line)
        for ch in line:
            if escaped:
                escaped = False
                continue
            if ch == "\\":
                escaped = True
                continue
            if ch == '"':
                in_string = not in_string
                continue
            if in_string:
                continue
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1

        if depth <= 0:
            joined = " ".join(buffer).strip()
            if joined:
                result.append(joined)
            buffer = []
            depth = 0
            in_string = False
            escaped = False

    # flush any remaining partial buffer
    if buffer:
        joined = " ".join(buffer).strip()
        if joined:
            result.append(joined)

    return result


def _sanitize_jsonl_lines(
    lines: list[str],
    tools_schema: dict[str, dict],
    contract_type: str,
    debug: bool = False,
) -> tuple[list[str], int]:
    """Keep only schema-valid JSON object lines; return (kept_lines, dropped_count)."""
    kept: list[str] = []
    dropped = 0
    reasons: dict[str, int] = {}

    def _note(reason: str) -> None:
        reasons[reason] = reasons.get(reason, 0) + 1

    for line in lines:
        raw = line.strip()
        if not raw:
            continue
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                normalized = normalize_training_row(parsed, tools_schema, contract_type=contract_type)
                if not has_parseable_tool_call(normalized, contract_type=contract_type):
                    dropped += 1
                    _note("no_parseable_tool_call")
                elif row_has_schema_errors(normalized, tools_schema, _validate_tool_parameters, contract_type=contract_type):
                    dropped += 1
                    # collect fine-grained reason for the first assistant message
                    msgs = normalized.get("messages", [])
                    assistant = next(
                        (m for m in msgs if isinstance(m, dict) and m.get("role") == "assistant"), None
                    )
                    if assistant:
                        payload = extract_tool_payload(normalized, contract_type=contract_type)
                        if not isinstance(payload, dict):
                            _note("payload_parse_error")
                        else:
                            tname = payload.get("name", "?")
                            if tname == "no_tool":
                                _note("no_tool_missing_reason")
                            elif tname not in tools_schema:
                                _note(f"unknown_tool:{tname}")
                            else:
                                errs = _validate_tool_parameters(
                                    tname, payload.get("arguments", {}), tools_schema[tname]
                                )
                                for e in errs:
                                    _note(f"param_err:{e[:60]}")
                    else:
                        _note("no_assistant_msg")
                else:
                    kept.append(json.dumps(normalized, ensure_ascii=False))
            else:
                dropped += 1
                _note("not_a_dict")
        except json.JSONDecodeError:
            dropped += 1
            _note("json_parse_error")

    if debug and reasons:
        top = sorted(reasons.items(), key=lambda x: -x[1])[:8]
        print("    Drop reasons: " + " | ".join(f"{r}={c}" for r, c in top))

    return kept, dropped


def _load_tool_names(tools_path: Path) -> list[str]:
    data = _load_tools_data(str(tools_path))

    names: list[str] = []
    if isinstance(data, dict):
        for tool in data.get("allTools", []):
            if not isinstance(tool, dict):
                continue
            name = tool.get("name")
            if isinstance(name, str) and name:
                names.append(name)

        # fallback to server-based view if allTools missing
        if not names:
            for server in data.get("servers", []):
                if not isinstance(server, dict):
                    continue
                for tool in server.get("tools", []):
                    if not isinstance(tool, dict):
                        continue
                    name = tool.get("name")
                    if isinstance(name, str) and name:
                        names.append(name)

    # OpenAI-style list format: [{"type":"function","function":{"name":"..."}}, ...]
    if isinstance(data, list):
        for item in data:
            if not isinstance(item, dict):
                continue
            fn = item.get("function")
            if not isinstance(fn, dict):
                continue
            name = fn.get("name")
            if isinstance(name, str) and name:
                names.append(name)

    names = sorted(set(names))
    if not names:
        raise SystemExit(f"No tools found in {tools_path}")
    return names


def _subset_tools_data(tools_data: object, selected_tool_names: list[str]) -> object:
    selected = set(selected_tool_names)

    if isinstance(tools_data, list):
        subset: list[dict] = []
        for item in tools_data:
            if not isinstance(item, dict):
                continue
            fn = item.get("function")
            if not isinstance(fn, dict):
                continue
            name = fn.get("name")
            if isinstance(name, str) and name in selected:
                subset.append(item)
        return subset

    if isinstance(tools_data, dict):
        copied = dict(tools_data)
        if isinstance(copied.get("allTools"), list):
            copied["allTools"] = [
                tool for tool in copied["allTools"]
                if isinstance(tool, dict) and tool.get("name") in selected
            ]
        if isinstance(copied.get("servers"), list):
            new_servers = []
            for server in copied["servers"]:
                if not isinstance(server, dict):
                    continue
                new_server = dict(server)
                tools = server.get("tools")
                if isinstance(tools, list):
                    new_server["tools"] = [
                        tool for tool in tools
                        if isinstance(tool, dict) and tool.get("name") in selected
                    ]
                new_servers.append(new_server)
            copied["servers"] = new_servers
        return copied

    return tools_data


def _chunked(items: list[str], chunk_size: int) -> Iterable[list[str]]:
    for i in range(0, len(items), chunk_size):
        yield items[i : i + chunk_size]


def _weather_tool_families(tool_names: list[str]) -> list[dict[str, object]]:
    """Group known weather tools into semantic families.

    This keeps batches coherent so Gemini sees related routing decisions together
    instead of arbitrary shuffled tool subsets.
    """

    preferred_families = [
        (
            "station_lookup",
            [
                "get_all_devices",
                "get_devices_by_name",
                "get_device_configuration",
                "get_device",
                "get_devices_around_position",
                "get_channel_names",
            ],
        ),
        (
            "measurement_exports",
            [
                "get_json_measurement_data",
                "get_csv_measurement_data",
                "get_excel_measurement_data",
                "get_json_measurement_data_by_name",
                "get_csv_measurement_data_by_name",
                "get_excel_measurement_data_by_name",
            ],
        ),
        (
            "server_time",
            [
                "get_server_datetime",
                "get_server_timestamp",
            ],
        ),
        (
            "forecast",
            [
                "get_weather_forecast",
            ],
        ),
        (
            "visualization",
            [
                "generate_interactive_map_html",
                "get_measurement_data_in_chart",
                "get_measurement_data_in_chart_by_name",
            ],
        ),
    ]

    available = set(tool_names)
    assigned: set[str] = set()
    families: list[dict[str, object]] = []

    for label, preferred_tools in preferred_families:
        present_tools = [tool for tool in preferred_tools if tool in available]
        if present_tools:
            families.append({"label": label, "tools": present_tools})
            assigned.update(present_tools)

    remaining = [tool for tool in tool_names if tool not in assigned]
    if remaining:
        families.append({"label": "misc", "tools": remaining})

    return families


def _expand_family_chunks(families: list[dict[str, object]], chunk_size: int) -> list[dict[str, object]]:
    chunk_specs: list[dict[str, object]] = []

    for family in families:
        label = str(family["label"])
        tools = list(family["tools"])
        family_chunks = list(_chunked(tools, max(1, chunk_size)))
        for idx, family_chunk in enumerate(family_chunks, start=1):
            chunk_label = label if len(family_chunks) == 1 else f"{label}_{idx}"
            chunk_specs.append({
                "label": chunk_label,
                "family": label,
                "tools": family_chunk,
            })

    return chunk_specs


def _extract_tool_name_from_line(json_line: str, contract_type: str) -> str:
    try:
        row = json.loads(json_line)
    except json.JSONDecodeError:
        return ""

    payload = extract_tool_payload(row, contract_type=contract_type)
    if not isinstance(payload, dict):
        return ""

    tool_name = payload.get("name")
    return tool_name if isinstance(tool_name, str) else ""


def _count_tool_usage(lines: list[str], contract_type: str) -> collections.Counter[str]:
    counts: collections.Counter[str] = collections.Counter()
    for line in lines:
        tool_name = _extract_tool_name_from_line(line, contract_type)
        if tool_name:
            counts[tool_name] += 1
    return counts


def _family_lookup(families: list[dict[str, object]]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for family in families:
        label = str(family["label"])
        for tool in family["tools"]:
            mapping[str(tool)] = label
    return mapping


def _print_coverage_summary(
    tool_names: list[str],
    families: list[dict[str, object]],
    usage_counts: collections.Counter[str],
) -> None:
    family_map = _family_lookup(families)
    family_counts: collections.Counter[str] = collections.Counter()

    print("Coverage summary by tool:")
    for tool_name in tool_names:
        count = usage_counts.get(tool_name, 0)
        family_label = family_map.get(tool_name, "misc")
        family_counts[family_label] += count
        print(f"  - {tool_name:<32} {count:>4}  ({family_label})")

    print("Coverage summary by family:")
    for family in families:
        label = str(family["label"])
        tools = list(family["tools"])
        total = family_counts.get(label, 0)
        avg = (total / len(tools)) if tools else 0.0
        print(f"  - {label:<20} total={total:>4} avg_per_tool={avg:.1f} tools={len(tools)}")


def _select_low_coverage_family(families: list[dict[str, object]], usage_counts: collections.Counter[str]) -> dict[str, object]:
    def family_score(family: dict[str, object]) -> tuple[float, int, str]:
        tools = list(family["tools"])
        if not tools:
            return (float("inf"), 0, str(family["label"]))
        per_tool_counts = [usage_counts.get(tool, 0) for tool in tools]
        avg_count = sum(per_tool_counts) / len(per_tool_counts)
        min_count = min(per_tool_counts)
        return (avg_count, min_count, str(family["label"]))

    return min(families, key=family_score)


def _extract_user_content(json_line: str) -> str:
    try:
        row = json.loads(json_line)
        msgs = row.get("messages", [])
        for m in msgs:
            if isinstance(m, dict) and m.get("role") == "user":
                content = m.get("content")
                if isinstance(content, str):
                    return content.strip().lower()
    except Exception:
        return ""
    return ""


def _dedupe_lines(lines: list[str]) -> list[str]:
    seen_lines: set[str] = set()
    seen_user_prompts: set[str] = set()
    out: list[str] = []

    for line in lines:
        if line in seen_lines:
            continue

        user_key = _extract_user_content(line)
        if user_key and user_key in seen_user_prompts:
            continue

        out.append(line)
        seen_lines.add(line)
        if user_key:
            seen_user_prompts.add(user_key)

    return out


def _build_chunk_prompt(
    base_prompt: str,
    chunk_tools: list[str],
    examples: int,
    tools_data: object,
    contract_type: str,
    focus_label: str | None = None,
) -> str:
    tools_text = ", ".join(chunk_tools)
    chunk_tools_json = json.dumps(
        _subset_tools_data(tools_data, chunk_tools),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    focus_text = ""
    if focus_label:
        focus_text = (
            "Semantic focus for this batch:\n"
            f"- Center the prompts on the '{focus_label}' tool family.\n"
            "- Prefer realistic routing decisions within this family and close contrasts against nearby alternatives.\n"
        )
    if contract_type == OLLAMA_NATIVE_CONTRACT:
        contract_rules = (
            "Every assistant tool-calling message must use empty string content and a tool_calls array like "
            "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"<tool>\",\"arguments\":{...}}}]}.\n"
            "Do not use the legacy tool_call: wrapper or alternate top-level keys.\n"
        )
    else:
        contract_rules = (
            "Every assistant tool-call line must start exactly with `tool_call: ` followed by a JSON object whose top-level keys are exactly `name` and `arguments`.\n"
            "Never use wrapper formats such as `{\"tool_call\": ...}`, `{\"tool\": ...}`, `{\"action\": ...}`, `{\"command\": ...}`, or `{\"parameters\": ...}` at the top level.\n"
        )
    return (
        base_prompt
        + "\n\n"
        + "## Additional Generation Constraints (STRICT)\n"
        + f"Generate exactly {examples} JSONL lines.\n"
        + "Output JSONL only, one object per line, no markdown and no comments.\n"
        + contract_rules
        + focus_text
        + "For this batch, use only these tool names (except optional no_tool negatives):\n"
        + tools_text
        + "\n"
        + "Use this ACTIVE TOOL SUBSET as the authoritative schema for this batch:\n"
        + chunk_tools_json
        + "\n"
        + "Coverage rule for this batch:\n"
        + "- Every listed tool must appear at least 2 times in this batch if feasible.\n"
        + "- Keep no_tool to <= 10% of lines.\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Incremental training-data generator")
    parser.add_argument("--prompt", default="scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/generated_train_prompt.md", help="Prompt markdown path")
    parser.add_argument("--tools", default="scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl", help="Tools JSON or JSONL schema path")
    parser.add_argument("--out", default="scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/train.jsonl", help="Output JSONL path")
    parser.add_argument("--model", default="deepseek-v4-pro", help="Example-generator model name")
    parser.add_argument("--total", type=int, default=1500, help="Target final line count")
    parser.add_argument("--min-valid", type=int, default=400, help="Minimum required count of schema-valid examples")
    parser.add_argument("--tools-per-chunk", type=int, default=5, help="How many tools each generation batch targets")
    parser.add_argument("--examples-per-chunk", type=int, default=90, help="Requested examples per batch")
    parser.add_argument("--seed", type=int, default=42, help="Shuffle seed")
    parser.add_argument("--attempts-per-chunk", type=int, default=4, help="Attempts for each tool chunk")
    parser.add_argument("--topup-rounds", type=int, default=8, help="Maximum top-up rounds when still below target")
    parser.add_argument("--topup-batch-size", type=int, default=180, help="Requested examples per top-up round")
    parser.add_argument("--repair-only", action="store_true", help="Repair existing JSONL file in --out without generating new data")
    parser.add_argument("--contract-type", default="text_tool_call", help="Contract type: text_tool_call or ollama_native")
    args = parser.parse_args()

    prompt_path = Path(args.prompt)
    tools_path = Path(args.tools)
    out_path = Path(args.out)

    if not prompt_path.exists():
        raise SystemExit(f"Prompt file not found: {prompt_path}")
    if not tools_path.exists():
        raise SystemExit(f"Tools file not found: {tools_path}")

    if args.total < 300:
        print("Requested --total is below 300; overriding to 300 for minimum dataset size.")
        args.total = 300

    if args.min_valid < 300:
        print("Requested --min-valid is below 300; overriding to 300.")
        args.min_valid = 300

    if args.topup_rounds < 1:
        print("Requested --topup-rounds is below 1; overriding to 1.")
        args.topup_rounds = 1

    if args.topup_batch_size < 50:
        print("Requested --topup-batch-size is too low; overriding to 50.")
        args.topup_batch_size = 50

    tools_schema = _load_tools_schema(str(tools_path))
    tools_data = _load_tools_data(str(tools_path))

    if args.repair_only:
        if not out_path.exists():
            raise SystemExit(f"Output file not found for repair: {out_path}")
        raw_lines = _non_empty_lines(out_path.read_text(encoding="utf-8"))
        cleaned_lines, dropped = _sanitize_jsonl_lines(raw_lines, tools_schema, args.contract_type, debug=True)
        cleaned_lines, prep_stats = prepare_training_lines(
            cleaned_lines,
            target_total=None,
            followup_ratio=0.1,
            contract_type=args.contract_type,
            tools_schema=tools_schema,
        )
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text("\n".join(cleaned_lines) + "\n", encoding="utf-8")
        print(f"Repair-only: kept {len(cleaned_lines)} lines, dropped {dropped} malformed lines")
        print(
            "Prepared dataset: "
            f"original={prep_stats['original_lines']} "
            f"followup={prep_stats['followup_lines']} "
            f"dropped_bad_no_tool={prep_stats['dropped_bad_no_tool']} "
            f"final={prep_stats['final_lines']}"
        )
        valid, errors = validate_jsonl(str(out_path), str(tools_path), contract_type=args.contract_type)
        print(f"Validation summary: valid={valid}, errors={errors}")
        if errors > 0 or valid < args.min_valid:
            raise SystemExit(1)
        return

    base_prompt = prompt_path.read_text(encoding="utf-8")

    tool_names = _load_tool_names(tools_path)
    families = _weather_tool_families(tool_names)
    chunk_specs = _expand_family_chunks(families, args.tools_per_chunk)

    # Keep semantic coverage chunks in family order; unlike random slicing, this
    # guarantees every major routing family gets at least one focused pass.
    selected_chunks = chunk_specs

    all_lines: list[str] = []
    print(f"Tools: {len(tool_names)} | Chunks: {len(selected_chunks)}")

    for idx, chunk_spec in enumerate(selected_chunks, start=1):
        chunk = list(chunk_spec["tools"])
        focus_label = str(chunk_spec["family"])
        print(f"Generating chunk {idx}/{len(selected_chunks)} with {len(chunk)} tools ({focus_label})")
        prompt = _build_chunk_prompt(
            base_prompt,
            chunk,
            args.examples_per_chunk,
            tools_data,
            args.contract_type,
            focus_label=focus_label,
        )

        best_lines: list[str] = []
        for attempt in range(1, args.attempts_per_chunk + 1):
            print(f"  Attempt {attempt}/{args.attempts_per_chunk}")
            text = generate_with_example_model(args.model, prompt, temperature=0.1, top_p=0.1)
            lines, dropped = _sanitize_jsonl_lines(_non_empty_lines(text), tools_schema, args.contract_type, debug=True)
            if dropped > 0:
                print(f"    Dropped {dropped} malformed or schema-invalid JSONL lines in this attempt")
            if len(lines) > len(best_lines):
                best_lines = lines
            if len(best_lines) >= args.examples_per_chunk:
                break

        all_lines.extend(best_lines)

    all_lines = _dedupe_lines(all_lines)

    # Top-up passes if too small after chunk generation.
    for round_index in range(1, args.topup_rounds + 1):
        if len(all_lines) >= args.total:
            break
        missing = args.total - len(all_lines)
        request_count = min(args.topup_batch_size, missing)
        usage_counts = _count_tool_usage(all_lines, args.contract_type)
        topup_family = _select_low_coverage_family(families, usage_counts)
        topup_family_label = str(topup_family["label"])
        topup_tools = list(topup_family["tools"])
        print(
            f"Top-up round {round_index}/{args.topup_rounds} for {missing} additional lines "
            f"(requesting {request_count}) targeting family '{topup_family_label}'"
        )
        topup_prompt = _build_chunk_prompt(
            base_prompt,
            topup_tools,
            request_count,
            tools_data,
            args.contract_type,
            focus_label=topup_family_label,
        )
        topup_text = generate_with_example_model(args.model, topup_prompt, temperature=0.1, top_p=0.1)
        topup_lines, topup_dropped = _sanitize_jsonl_lines(_non_empty_lines(topup_text), tools_schema, args.contract_type, debug=True)
        if topup_dropped > 0:
            print(f"Dropped {topup_dropped} malformed or schema-invalid JSONL lines in top-up round {round_index}")
        all_lines.extend(topup_lines)
        all_lines = _dedupe_lines(all_lines)

    final_lines, prep_stats = prepare_training_lines(
        all_lines,
        target_total=None,
        followup_ratio=0.1,
        contract_type=args.contract_type,
        tools_schema=tools_schema,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(final_lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(final_lines)} lines to {out_path}")
    print(
        "Prepared dataset: "
        f"original={prep_stats['original_lines']} "
        f"followup={prep_stats['followup_lines']} "
        f"dropped_bad_no_tool={prep_stats['dropped_bad_no_tool']} "
        f"final={prep_stats['final_lines']}"
    )

    usage_counts = _count_tool_usage(final_lines, args.contract_type)
    _print_coverage_summary(tool_names, families, usage_counts)

    valid, errors = validate_jsonl(str(out_path), str(tools_path), contract_type=args.contract_type)
    print(f"Validation summary: valid={valid}, errors={errors}")
    if errors > 0:
        print(f"Validation errors remain: errors={errors}, valid={valid}")
        raise SystemExit(1)
    if valid < args.min_valid:
        print(f"Warning: valid={valid} is below min_valid={args.min_valid}, but file was written successfully.")


if __name__ == "__main__":
    main()
