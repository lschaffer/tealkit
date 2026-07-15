#!/usr/bin/env python3
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOOLS_PATH = ROOT / "mcp_data" / "mcp_tools.json"
OUT_PATH = ROOT / "mcp_data" / "train.jsonl"


def sample_for_type(schema_type, key_name="", item_schema=None, default=None):
    k = (key_name or "").lower()
    if default is not None:
        return default

    if schema_type == "string":
        if "city" in k:
            return "Vienna"
        if "query" in k or "prompt" in k or "search" in k:
            return "weather forecast"
        if "url" in k:
            return "https://example.com"
        if "email" in k:
            return "demo@example.com"
        if "path" in k or "file" in k:
            return "/tmp/sample.txt"
        if "cron" in k:
            return "0 */6 * * *"
        if "timezone" in k:
            return "Europe/Vienna"
        if "name" in k:
            return "demo"
        return "sample"

    if schema_type == "integer":
        if "hour" in k or "hours" in k:
            return 24
        if "day" in k:
            return 7
        if "limit" in k:
            return 10
        if "port" in k:
            return 8080
        return 1

    if schema_type == "number":
        if "lat" in k:
            return 48.2082
        if "lon" in k or "lng" in k:
            return 16.3738
        return 1.0

    if schema_type == "boolean":
        return True

    if schema_type == "array":
        t = "string"
        if isinstance(item_schema, dict):
            t = item_schema.get("type", "string")
        if t == "number":
            return [1.0, 2.0, 3.0]
        if t == "integer":
            return [1, 2, 3]
        if t == "object":
            return [{"name": "series", "data": [1.0, 2.0, 3.0]}]
        return ["a", "b", "c"]

    if schema_type == "object":
        return {}

    return "sample"


def build_required_params(input_schema):
    params = {}
    props = input_schema.get("properties", {}) if isinstance(input_schema, dict) else {}
    required = input_schema.get("required", []) if isinstance(input_schema, dict) else []

    for key in required:
        ps = props.get(key, {}) if isinstance(props, dict) else {}
        ptype = ps.get("type", "string")
        default = ps.get("default")
        item_schema = ps.get("items") if isinstance(ps, dict) else None
        params[key] = sample_for_type(ptype, key_name=key, item_schema=item_schema, default=default)

    return params


def make_example(user_text, tool_name, params):
    payload = {"name": tool_name, "arguments": params}
    return {
        "messages": [
            {"role": "user", "content": user_text},
            {"role": "assistant", "content": "tool_call: " + json.dumps(payload, ensure_ascii=False)},
        ]
    }


def main():
    data = json.loads(TOOLS_PATH.read_text(encoding="utf-8"))
    tools = []
    for server in data.get("servers", []):
        for tool in server.get("tools", []):
            name = tool.get("name")
            schema = tool.get("inputSchema", {})
            if isinstance(name, str) and name:
                tools.append((name, schema))

    examples = []
    for name, schema in tools:
        params = build_required_params(schema)
        examples.append(make_example(f"Run {name} with the required parameters.", name, params))
        examples.append(make_example(f"Please call {name} now.", name, params))

    no_tool_prompts = [
        "Write me a romantic poem in old Norse.",
        "Compose a guitar tab for a jazz solo.",
        "Generate a 3D game engine in Rust.",
        "Translate this to Klingon and explain grammar.",
        "Predict stock prices for next year with certainty.",
    ]
    for p in no_tool_prompts:
        examples.append(
            make_example(p, "no_tool", {"reason": "No matching MCP tool for this request"})
        )

    random.shuffle(examples)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUT_PATH.open("w", encoding="utf-8") as f:
        for ex in examples:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    print(f"Wrote {len(examples)} examples to {OUT_PATH}")


if __name__ == "__main__":
    main()
