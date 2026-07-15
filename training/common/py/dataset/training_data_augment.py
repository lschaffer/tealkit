from __future__ import annotations

import json
import re
from typing import Any

from common.py.dataset.gemini_generation_common import (
    OLLAMA_NATIVE_CONTRACT,
    TEXT_TOOL_CALL_CONTRACT,
    build_native_tool_call,
    extract_tool_payload,
    normalize_contract_type,
)


QUALITY_GATE_EXEMPLAR_REPEAT = 8

# Known domain tool families used for domain detection
_WEATHER_TOOL_NAMES = frozenset({
    "get_devices_by_name", "get_csv_measurement_data", "get_weather_forecast",
    "get_server_datetime", "get_server_timestamp", "get_device",
    "get_all_devices", "get_channel_names", "get_devices_around_position",
    "get_device_configuration", "get_csv_measurement_data_by_name",
    "get_json_measurement_data", "get_json_measurement_data_by_name",
    "get_excel_measurement_data", "get_excel_measurement_data_by_name",
    "get_measurement_data_in_chart", "get_measurement_data_in_chart_by_name",
    "generate_interactive_map_html",
})

_WEBCRAWL_TOOL_NAMES = frozenset({
    "index_websites", "reindex_websites", "purge_stale_index",
    "list_indexed_pages", "search_indexed_websites", "get_indexed_page",
})


def _detect_domain(tools_schema: dict[str, dict]) -> str | None:
    """Detect the training domain from the available tool schema.

    Returns 'weather', 'webcrawl', or None if unknown.
    """
    available = set(tools_schema.keys())
    if available & _WEATHER_TOOL_NAMES:
        return "weather"
    if available & _WEBCRAWL_TOOL_NAMES:
        return "webcrawl"
    return None


def _first_message(messages: list[dict[str, Any]], role: str) -> dict[str, Any] | None:
    for message in messages:
        if isinstance(message, dict) and message.get("role") == role:
            return message
    return None


def _dedupe_lines(lines: list[str], protected_lines: set[str] | None = None) -> list[str]:
    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        if protected_lines and line in protected_lines:
            output.append(line)
            continue
        if line in seen:
            continue
        seen.add(line)
        output.append(line)
    return output


def _normalize_no_tool_reason(reason: str) -> str:
    text = " ".join(reason.strip().split())
    if not text:
        return "not supported"

    lowered = text.lower()
    specialized_rules = [
        ((("one action at a time", "please ask")), "multiple actions not supported"),
        ((("latitude", "longitude")), "coordinates required"),
        ((("missing coordinates",)), "coordinates required"),
        ((("device id",)), "device id required"),
        ((("pdf reports",)), "coordinates required"),
        ((("current data",)), "current data available via device lookup"),
        ((("device lookup",)), "device lookup available"),
        ((("station lookup",)), "device lookup available"),
        ((("server time",)), "server time available"),
        (("missing coordinates",), "coordinates required"),
        (("device id",), "device id required"),
        (("pdf reports",), "coordinates required"),
        (("current data",), "current data available via device lookup"),
        (("device lookup",), "device lookup available"),
        (("station lookup",), "device lookup available"),
        (("server time",), "server time available"),
        (("historical",), "historical data requires measurement tools"),
        (("email",), "email sending not supported"),
        (("3d", "map"), "3d maps not supported"),
        (("animated", "map"), "animated maps not supported"),
        (("forecast", "plot"), "forecast plotting not supported"),
        (("reboot",), "device control not supported"),
        (("delete",), "device deletion not supported"),
        (("create", "device"), "device creation not supported"),
        (("configuration log",), "configuration log export not supported"),
    ]
    for needles, replacement in specialized_rules:
        if all(needle in lowered for needle in needles):
            return replacement

    sentence = re.split(r"[.!?]", text, maxsplit=1)[0].strip()
    sentence = re.sub(r"^(i can only|i can|i cannot|i am unable to|please|the tools are for)\s+", "", sentence, flags=re.IGNORECASE)
    sentence = re.sub(r"\s*,?\s*but\s+.*$", "", sentence, flags=re.IGNORECASE)
    sentence = sentence.strip(" .,:;-")
    words = sentence.split()
    if not words:
        return "not supported"
    if len(words) > 8:
        words = words[:8]
    return " ".join(words)


def _should_drop_no_tool_row(user_text: str, reason: str) -> bool:
    prompt = user_text.lower()
    normalized_reason = reason.lower()

    if any(token in prompt for token in ["current time", "server time", "server date", "server timestamp", "what time is it", "time now"]):
        return True

    if any(token in prompt for token in ["current weather", "latest weather", "current temperature", "current data", "latest data"]):
        return True

    if any(token in prompt for token in ["id of", "device id", "station id", "lookup station", "find station", "show me device", "device status"]):
        return True

    if ("map of all stations" in prompt or "map of all devices" in prompt or "show me a map of all stations" in prompt) and "3d" not in prompt and "animate" not in prompt:
        return True

    if "forecast" in prompt and ("station" in prompt or "device" in prompt) and "coordinates required" in normalized_reason:
        return True

    if "forecast" in prompt and any(token in prompt for token in ["pdf", "report"]) and "coordinates required" not in normalized_reason:
        return True

    if any(token in prompt for token in ["yesterday", "last 6 hours", "last 24 hours", "historical"]) and any(token in prompt for token in ["temperature", "weather", "measurement", "csv", "excel", "json"]):
        return True

    return False


def _tool_payload_from_row(row: dict[str, Any], contract_type: str = TEXT_TOOL_CALL_CONTRACT) -> tuple[str, dict[str, Any]]:
    payload = extract_tool_payload(row, contract_type=contract_type)
    if not isinstance(payload, dict):
        return "", {}

    name = payload.get("name")
    arguments = payload.get("arguments")
    if not isinstance(name, str) or not isinstance(arguments, dict):
        return "", {}
    return name, arguments


def _replace_first_assistant_content(
    messages: list[dict[str, Any]],
    new_content: str,
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
) -> bool:
    normalized_contract = normalize_contract_type(contract_type)
    for message in messages:
        if isinstance(message, dict) and message.get("role") == "assistant":
            if normalized_contract == OLLAMA_NATIVE_CONTRACT:
                try:
                    payload = json.loads(new_content[len("tool_call: ") :])
                except Exception:
                    return False
                message["content"] = ""
                message["tool_calls"] = [build_native_tool_call(payload)]
            else:
                message["content"] = new_content
            return True
    return False


def _canonicalize_weather_lookup_row(
    row: dict[str, Any],
    user_text: str,
    tool_name: str,
    arguments: dict[str, Any],
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
    tools_schema: dict[str, dict] | None = None,
) -> bool:
    # Only apply weather canonicalization if weather tools are actually available
    if tools_schema and "get_devices_by_name" not in tools_schema and "get_csv_measurement_data" not in tools_schema:
        return False
    if tool_name != "get_device":
        return False

    lowered = user_text.lower()
    grp_id = int(arguments.get("grpId", -1)) if str(arguments.get("grpId", "-1")).lstrip("-").isdigit() else -1

    if any(token in lowered for token in ["latest reading", "last recorded measurement", "last measurement"]):
        dlu_name = arguments.get("dlu_name")
        dlu_id = arguments.get("dlu_id")
        if isinstance(dlu_name, str) and dlu_name.strip():
            replacement = {
                "name": "get_csv_measurement_data_by_name",
                "arguments": {
                    "dluName": dlu_name.strip(),
                    "channels": "[ALL]",
                    "maxRows": 1,
                    "fromLast": True,
                },
            }
        else:
            if dlu_id is None:
                match = re.search(r"\bstation\s+(\d+)\b", lowered)
                if match:
                    dlu_id = int(match.group(1))
            if dlu_id is None:
                return False

            replacement = {
                "name": "get_csv_measurement_data",
                "arguments": {
                    "dlu_id": dlu_id,
                    "channels": "[ALL]",
                    "maxRows": 1,
                    "fromLast": True,
                },
            }
    else:
        if not any(token in lowered for token in ["current weather", "latest weather", "current data", "latest data", "weather data", "weather forecast"]):
            return False

        station_name = None
        match = re.search(r"\b(DLU-[A-Za-z0-9_-]+)\b", user_text, flags=re.IGNORECASE)
        if match:
            station_name = match.group(1).upper()
        elif isinstance(arguments.get("dlu_name"), str) and str(arguments.get("dlu_name")).strip():
            station_name = str(arguments.get("dlu_name")).strip()

        if not station_name:
            return False

        replacement = {
            "name": "get_devices_by_name",
            "arguments": {
                "dluName": station_name,
                "detail": 1,
                "grpId": grp_id,
            },
        }

    messages = row.get("messages")
    if not isinstance(messages, list):
        return False

    return _replace_first_assistant_content(
        messages,
        f"tool_call: {json.dumps(replacement, ensure_ascii=False)}",
        contract_type=contract_type,
    )


def _build_weather_quality_gate_exemplars() -> list[dict[str, Any]]:
    """Quality gate exemplars for the weather/sensor domain."""
    return [
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Get the latest weather data for station DLU-123. Respond ONLY with a tool_call JSON object.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"get_devices_by_name\", \"arguments\": {\"dluName\": \"DLU-123\", \"detail\": 1, \"grpId\": -1}}",
                },
            ]
        },
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Show rainfall measurements for device 1234 between 20240301000000 and 20240303235959 as CSV. Respond ONLY with a tool_call JSON object.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"get_csv_measurement_data\", \"arguments\": {\"dlu_id\": 1234, \"fromDate\": \"20240301000000\", \"toDate\": \"20240303235959\", \"channels\": \"[ALL]\"}}",
                },
            ]
        },
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Give me a 12 hour forecast for coordinates 52.52, 13.405. Respond ONLY with a tool_call JSON object.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"get_weather_forecast\", \"arguments\": {\"lat\": 52.52, \"lng\": 13.405, \"hours\": 12}}",
                },
            ]
        },
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Original request: What is the current server time?\nReturn the tool call first. After the tool result arrives, answer with the result only.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"get_server_datetime\", \"arguments\": {}}",
                },
                {
                    "role": "user",
                    "content": "Tool result for the previous call:\n{\"server_datetime\": \"2026-05-20 14:30:00\"}\nNow answer the original request using only this result. No suggestions. No follow-up questions.",
                },
                {
                    "role": "assistant",
                    "content": "2026-05-20 14:30:00",
                },
            ]
        },
    ]


def _build_webcrawl_quality_gate_exemplars() -> list[dict[str, Any]]:
    """Quality gate exemplars for the webcrawl domain."""
    return [
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Search for information about machine learning in my indexed websites. Respond ONLY with a tool_call JSON object.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"search_indexed_websites\", \"arguments\": {\"query\": \"machine learning\", \"searchMode\": \"hybrid\"}}",
                },
            ]
        },
        {
            "messages": [
                {
                    "role": "user",
                    "content": "What pages are currently indexed for example.com? Respond ONLY with a tool_call JSON object.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"list_indexed_pages\", \"arguments\": {\"domain\": \"example.com\", \"limit\": 50}}",
                },
            ]
        },
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Index my website. Respond ONLY with a tool_call JSON object.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"index_websites\", \"arguments\": {}}",
                },
            ]
        },
        {
            "messages": [
                {
                    "role": "user",
                    "content": "Original request: Show me the full content of https://example.com/about\nReturn the tool call first. After the tool result arrives, answer with the result only.",
                },
                {
                    "role": "assistant",
                    "content": "tool_call: {\"name\": \"get_indexed_page\", \"arguments\": {\"url\": \"https://example.com/about\"}}",
                },
                {
                    "role": "user",
                    "content": "Tool result for the previous call:\n{\"url\": \"https://example.com/about\", \"title\": \"About Us\", \"content\": \"We are a company...\"}\nNow answer the original request using only this result. No suggestions. No follow-up questions.",
                },
                {
                    "role": "assistant",
                    "content": "Title: About Us\nContent: We are a company...",
                },
            ]
        },
    ]


def _quality_gate_exemplar_lines(
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
    tools_schema: dict[str, dict] | None = None,
) -> list[str]:
    domain = _detect_domain(tools_schema) if tools_schema else None

    if domain == "weather":
        rows = _build_weather_quality_gate_exemplars()
    elif domain == "webcrawl":
        rows = _build_webcrawl_quality_gate_exemplars()
    else:
        # Unknown domain: return empty exemplar list to avoid injecting
        # domain-inappropriate tool calls
        return []

    if normalize_contract_type(contract_type) == OLLAMA_NATIVE_CONTRACT:
        for row in rows:
            messages = row.get("messages", [])
            for message in messages:
                if not isinstance(message, dict) or message.get("role") != "assistant":
                    continue
                content = message.get("content")
                if not isinstance(content, str) or not content.startswith("tool_call: "):
                    continue
                payload = json.loads(content[len("tool_call: ") :])
                message["content"] = ""
                message["tool_calls"] = [build_native_tool_call(payload)]
                break
    return [json.dumps(row, ensure_ascii=False) for row in rows]


def _normalize_row(
    line: str,
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
    tools_schema: dict[str, dict] | None = None,
) -> tuple[str | None, bool]:
    row = json.loads(line)
    messages = row.get("messages")
    if not isinstance(messages, list):
        return line, False

    user = _first_message(messages, "user")
    user_text = str(user.get("content", "")).strip() if isinstance(user, dict) else ""
    tool_name, arguments = _tool_payload_from_row(row, contract_type=contract_type)

    if tool_name and _canonicalize_weather_lookup_row(
        row, user_text, tool_name, arguments,
        contract_type=contract_type, tools_schema=tools_schema,
    ):
        return json.dumps(row, ensure_ascii=False), False

    if tool_name == "no_tool":
        reason = arguments.get("reason")
        if isinstance(reason, str):
            normalized_reason = _normalize_no_tool_reason(reason)
            if _should_drop_no_tool_row(user_text, normalized_reason):
                return None, True
            arguments["reason"] = normalized_reason
            return json.dumps(row, ensure_ascii=False), False

    return json.dumps(row, ensure_ascii=False), False


def _tool_result_stub(
    tool_name: str,
    arguments: dict[str, Any],
    tools_schema: dict[str, dict] | None = None,
) -> tuple[dict[str, Any], str] | None:
    # --- Webcrawl stubs ---
    if tool_name == "search_indexed_websites":
        query = arguments.get("query", "")
        return (
            {"results": [{"title": f"Result for {query}", "url": f"https://example.com/{query.replace(' ', '_')}", "snippet": f"Content about {query}"}]},
            f"Found results for '{query}'.",
        )

    if tool_name == "list_indexed_pages":
        domain = arguments.get("domain", "")
        pages = [
            {"url": f"https://{domain or 'example.com'}/page1", "title": "Page 1", "last_indexed": "2026-06-01"},
            {"url": f"https://{domain or 'example.com'}/page2", "title": "Page 2", "last_indexed": "2026-06-01"},
        ]
        return ({"pages": pages, "total": 2}, f"Listed {len(pages)} indexed pages.")

    if tool_name == "get_indexed_page":
        url = arguments.get("url", "")
        return (
            {"url": url, "title": url.rstrip("/").split("/")[-1].replace("_", " ").title(), "content": f"Full content of {url}"},
            f"Retrieved content from {url}",
        )

    if tool_name in {"index_websites", "reindex_websites", "purge_stale_index"}:
        return ({"status": "ok", "pages_indexed": 42}, "Website indexing completed successfully.")

    # --- Weather stubs (only returned if weather tools are in schema) ---
    domain = _detect_domain(tools_schema) if tools_schema else None
    if domain != "weather":
        return None

    if tool_name == "get_server_datetime":
        return ({"server_datetime": "2026-05-20 14:30:00"}, "2026-05-20 14:30:00")

    if tool_name == "get_server_timestamp":
        return ({"server_timestamp": 1747747800}, "1747747800")

    if tool_name == "get_channel_names":
        return ({"channels": [{"id": 0, "name": "Temperature"}]}, "Temperature")

    if tool_name == "get_weather_forecast":
        output = str(arguments.get("output", "text"))
        if output in {"pdf", "excel"}:
            label = "PDF" if output == "pdf" else "Excel"
            return ({"status": "ok", "file_type": output, "hours": arguments.get("hours", 12)}, f"The {label} forecast file is ready.")
        return ({"summary": "Light rain", "temperature_c": 17, "hours": arguments.get("hours", 12)}, "Light rain, 17 C.")

    if tool_name in {"get_csv_measurement_data", "get_json_measurement_data", "get_excel_measurement_data", "get_csv_measurement_data_by_name", "get_json_measurement_data_by_name", "get_excel_measurement_data_by_name"}:
        if tool_name in {"get_excel_measurement_data", "get_excel_measurement_data_by_name"}:
            return ({"status": "ok", "file_type": "xlsx", "rows": 24}, "The Excel measurement file is ready.")
        output_type = str(arguments.get("output_type", "text"))
        if output_type == "file":
            label = "JSON" if tool_name in {"get_json_measurement_data", "get_json_measurement_data_by_name"} else "CSV"
            return ({"status": "ok", "file_type": output_type, "rows": 24}, f"The {label} measurement file is ready.")
        return ({"rows": 24, "series": ["temperature"]}, "Returned 24 measurement rows.")

    if tool_name in {"get_measurement_data_in_chart", "get_measurement_data_in_chart_by_name"}:
        output = str(arguments.get("output", "png"))
        label = {"png": "PNG", "pdf": "PDF", "excel": "Excel"}.get(output, output.upper())
        return ({"status": "ok", "output": output}, f"The {label} chart is ready.")

    if tool_name == "generate_interactive_map_html":
        return ({"status": "ok", "file_type": "html"}, "The HTML map is ready.")

    if tool_name in {"get_all_devices", "get_devices_by_name", "get_devices_around_position"}:
        if str(arguments.get("output", "text")) == "file":
            format_name = str(arguments.get("format", "json")).upper()
            return ({"status": "ok", "format": arguments.get("format", "json")}, f"The {format_name} device export is ready.")
        return ({"devices": [{"name": "Demo Device", "dlu_id": 101, "temperatur": 17.4}]}, "Found 1 matching device.")

    if tool_name == "get_device":
        return ({"device": {"name": "Demo Device", "dlu_id": arguments.get("dlu_id", 101)}}, "Device details retrieved.")

    if tool_name == "get_device_configuration":
        return ({"device": {"name": "Demo Device", "config_version": "1.0"}}, "Device configuration retrieved.")

    return None


def synthesize_followup_rows(
    lines: list[str],
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
    tools_schema: dict[str, dict] | None = None,
) -> list[str]:
    synthesized: list[str] = []

    for line in lines:
        row = json.loads(line)
        messages = row.get("messages")
        if not isinstance(messages, list):
            continue

        user = _first_message(messages, "user")
        user_text = str(user.get("content", "")).strip() if isinstance(user, dict) else ""
        if not user_text:
            continue
        if user_text.startswith("Original request:"):
            continue

        tool_name, arguments = _tool_payload_from_row(row, contract_type=contract_type)
        if not tool_name or tool_name == "no_tool":
            continue

        result_stub = _tool_result_stub(tool_name, arguments, tools_schema=tools_schema)
        if result_stub is None:
            continue

        tool_result, final_answer = result_stub
        followup_row = {
            "messages": [
                {
                    "role": "user",
                    "content": (
                        f"Original request: {user_text}\n"
                        "Return the tool call first. After the tool result arrives, answer with the result only."
                    ),
                },
                messages[1],
                {
                    "role": "user",
                    "content": (
                        "Tool result for the previous call:\n"
                        f"{json.dumps(tool_result, ensure_ascii=False)}\n"
                        "Now answer the original request using only this result. No suggestions. No follow-up questions."
                    ),
                },
                {"role": "assistant", "content": final_answer},
            ]
        }
        synthesized.append(json.dumps(followup_row, ensure_ascii=False))

    return _dedupe_lines(synthesized)


def prepare_training_lines(
    lines: list[str],
    target_total: int | None,
    followup_ratio: float = 0.25,
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
    tools_schema: dict[str, dict] | None = None,
) -> tuple[list[str], dict[str, int]]:
    normalized_lines: list[str] = []
    dropped_no_tool = 0

    for line in lines:
        normalized, was_dropped = _normalize_row(line, contract_type=contract_type, tools_schema=tools_schema)
        if was_dropped:
            dropped_no_tool += 1
            continue
        if normalized:
            normalized_lines.append(normalized)

    normalized_lines = _dedupe_lines(normalized_lines)
    quality_gate_examples = _quality_gate_exemplar_lines(contract_type=contract_type, tools_schema=tools_schema)
    protected_examples = set(quality_gate_examples)
    weighted_examples = quality_gate_examples * QUALITY_GATE_EXEMPLAR_REPEAT
    normalized_lines = _dedupe_lines(weighted_examples + normalized_lines, protected_lines=protected_examples)
    followup_lines = synthesize_followup_rows(
        _dedupe_lines(quality_gate_examples + normalized_lines),
        contract_type=contract_type,
        tools_schema=tools_schema,
    )

    if target_total is None or target_total <= 0:
        final_lines = _dedupe_lines(normalized_lines + followup_lines, protected_lines=protected_examples)
    else:
        desired_followups = min(len(followup_lines), max(1, int(target_total * followup_ratio))) if followup_lines else 0
        desired_original = max(0, target_total - desired_followups)

        selected_original = normalized_lines[:desired_original]
        selected_followups = followup_lines[:desired_followups]

        final_lines: list[str] = []
        max_len = max(len(selected_original), len(selected_followups))
        for index in range(max_len):
            if index < len(selected_original):
                final_lines.append(selected_original[index])
            if index < len(selected_followups):
                final_lines.append(selected_followups[index])

        if len(final_lines) < target_total:
            remainder = normalized_lines[desired_original:] + followup_lines[desired_followups:]
            for line in remainder:
                if len(final_lines) >= target_total:
                    break
                final_lines.append(line)

        final_lines = _dedupe_lines(final_lines, protected_lines=protected_examples)[:target_total]

    stats = {
        "original_lines": len(normalized_lines),
        "followup_lines": len(followup_lines),
        "dropped_bad_no_tool": dropped_no_tool,
        "prepended_quality_gate_examples": len(quality_gate_examples),
        "weighted_quality_gate_examples": len(weighted_examples),
        "final_lines": len(final_lines),
    }
    return final_lines, stats
