#!/usr/bin/env python3
"""Shared validator for MCP tool-calling training JSONL data."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


SCRIPT_FILE = Path(__file__).resolve()
SCRIPTS_TRAINING_ROOT = SCRIPT_FILE.parents[3]
if str(SCRIPTS_TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_TRAINING_ROOT))

from common.py.dataset.gemini_generation_common import (
    OLLAMA_NATIVE_CONTRACT,
    TEXT_TOOL_CALL_CONTRACT,
    extract_tool_payload_from_assistant,
    normalize_contract_type,
)


def _load_tools_data(tools_file: str) -> Any:
    with open(tools_file, "r", encoding="utf-8") as handle:
        raw = handle.read().strip()

    if not raw:
        return []

    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        items = []
        for line in raw.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            items.append(json.loads(stripped))
        return items


def _load_tools_schema(tools_file: str) -> dict[str, dict[str, Any]]:
    if not os.path.exists(tools_file):
        raise FileNotFoundError(f"Tools schema not found: {tools_file}")

    data = _load_tools_data(tools_file)
    by_name: dict[str, dict[str, Any]] = {}

    if isinstance(data, dict):
        for server in data.get("servers", []):
            if not isinstance(server, dict):
                continue
            for tool in server.get("tools", []):
                if not isinstance(tool, dict):
                    continue
                name = tool.get("name")
                if isinstance(name, str) and name:
                    schema = tool.get("inputSchema", {})
                    by_name[name] = schema if isinstance(schema, dict) else {}

    if isinstance(data, list):
        for item in data:
            if not isinstance(item, dict):
                continue
            fn = item.get("function")
            if not isinstance(fn, dict):
                continue
            name = fn.get("name")
            if not (isinstance(name, str) and name):
                continue
            schema = fn.get("parameters", {})
            by_name[name] = schema if isinstance(schema, dict) else {}

    return by_name


def _type_ok(value: Any, schema_type: str) -> bool:
    if schema_type == "string":
        return isinstance(value, str)
    if schema_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if schema_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if schema_type == "boolean":
        return isinstance(value, bool)
    if schema_type == "array":
        return isinstance(value, list)
    if schema_type == "object":
        return isinstance(value, dict)
    return True


def _validate_tool_parameters(tool_name: str, params: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
    required = schema.get("required", []) if isinstance(schema, dict) else []

    if not isinstance(properties, dict):
        properties = {}
    if not isinstance(required, list):
        required = []

    for req in required:
        if req not in params:
            prop = properties.get(req, {})
            if isinstance(prop, dict) and "default" in prop:
                continue
            errors.append(f"missing required parameter '{req}' for tool '{tool_name}'")

    for key, value in params.items():
        if key not in properties:
            errors.append(f"unknown parameter '{key}' for tool '{tool_name}'")
            continue

        prop_schema = properties.get(key, {})
        expected_type = prop_schema.get("type") if isinstance(prop_schema, dict) else None
        if isinstance(expected_type, str) and not _type_ok(value, expected_type):
            errors.append(
                f"parameter '{key}' for tool '{tool_name}' has wrong type: expected {expected_type}, got {type(value).__name__}"
            )

    return errors


def validate_jsonl(
    file_path: str,
    tools_file: str,
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
) -> tuple[int, int]:
    if not os.path.exists(file_path):
        print(f"ERROR: File not found: {file_path}")
        return 0, 1

    try:
        tools = _load_tools_schema(tools_file)
    except Exception as exc:
        print(f"ERROR: Failed to load tools schema: {exc}")
        return 0, 1

    normalized_contract = normalize_contract_type(contract_type)

    print(f"Validating JSONL: {file_path}")
    print(f"Using tools schema: {tools_file} ({len(tools)} tools)")
    print(f"Contract type: {normalized_contract}")

    valid_count = 0
    error_count = 0

    with open(file_path, "r", encoding="utf-8") as handle:
        for line_num, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue

            line_errors: list[str] = []

            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"Line {line_num}: invalid JSON: {exc}")
                error_count += 1
                continue

            messages = item.get("messages")
            if not isinstance(messages, list) or len(messages) < 2:
                line_errors.append("messages must be a list with at least 2 entries")
            else:
                for msg in messages:
                    if not isinstance(msg, dict):
                        line_errors.append("message entry must be an object")
                        continue
                    if "role" not in msg:
                        line_errors.append("message missing 'role'")
                    elif msg.get("role") != "assistant" and "content" not in msg:
                        line_errors.append("message missing 'content'")

                assistant = next((m for m in messages if isinstance(m, dict) and m.get("role") == "assistant"), None)
                if assistant is None:
                    line_errors.append("no assistant message found")
                else:
                    payload = extract_tool_payload_from_assistant(assistant, normalized_contract)
                    if normalized_contract == OLLAMA_NATIVE_CONTRACT:
                        tool_calls = assistant.get("tool_calls")
                        if not isinstance(tool_calls, list) or not tool_calls:
                            line_errors.append("assistant.tool_calls must be a non-empty list")
                        content = assistant.get("content")
                        if content is None:
                            line_errors.append("assistant content must be present for ollama_native")
                        elif not isinstance(content, str):
                            line_errors.append("assistant content must be a string")
                        elif content.strip():
                            line_errors.append("assistant content must be empty when tool_calls are present")
                    else:
                        content = assistant.get("content", "")
                        if not isinstance(content, str) or not content.startswith("tool_call: "):
                            line_errors.append("assistant content must start with 'tool_call: '")

                    if isinstance(payload, dict):
                        tool_name = payload.get("name")
                        tool_args = payload.get("arguments")

                        if not isinstance(tool_name, str) or not tool_name:
                            line_errors.append("tool call name must be a non-empty string")
                        if not isinstance(tool_args, dict):
                            line_errors.append("tool call arguments must be an object")

                        if isinstance(tool_name, str) and isinstance(tool_args, dict):
                            if tool_name == "no_tool":
                                if "reason" not in tool_args:
                                    line_errors.append("no_tool requires arguments.reason")
                            elif tool_name not in tools:
                                line_errors.append(f"unknown tool name '{tool_name}'")
                            else:
                                line_errors.extend(_validate_tool_parameters(tool_name, tool_args, tools[tool_name]))
                    elif normalized_contract == OLLAMA_NATIVE_CONTRACT:
                        line_errors.append("assistant must contain native tool_calls with function.name and function.arguments")
                    else:
                        line_errors.append("tool_call payload is not valid JSON")

            if line_errors:
                error_count += 1
                print(f"Line {line_num}:")
                for err in line_errors:
                    print(f"  - {err}")
            else:
                valid_count += 1

    print("-" * 48)
    print(f"Valid lines: {valid_count}")
    print(f"Error lines: {error_count}")
    return valid_count, error_count


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate MCP tool-calling training JSONL data.")
    parser.add_argument("--jsonl", default="scripts_training/servers/weathersensorsmcp/datasets/text_tool_call/train.jsonl", help="Path to training JSONL file")
    parser.add_argument("--tools", default="scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl", help="Path to MCP tools schema JSON or JSONL")
    parser.add_argument("--contract-type", default=TEXT_TOOL_CALL_CONTRACT, help="Contract type: text_tool_call or ollama_native")
    args = parser.parse_args()

    _, errors = validate_jsonl(args.jsonl, args.tools, contract_type=args.contract_type)
    if errors > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
