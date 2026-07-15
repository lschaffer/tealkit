#!/usr/bin/env python3
"""Shared quality gate core for trained local models.

Runs a small probe suite against a local Ollama model and rejects obviously
wrong or degenerated outputs. Supports both built-in profiles and external
JSON profile files so contract-specific wrappers do not need to duplicate the
core evaluation logic.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_PROBES = [
    {
        "prompt": "What is the capital of Australia? Respond ONLY with a tool_call JSON object.",
        "expect": "json_tool_call",
    },
    {
        "prompt": "Get forecast for next 12 hours for my location. Respond ONLY with a tool_call JSON object.",
        "expect": "json_tool_call",
    },
    {
        "prompt": "list tools. Respond ONLY with a tool_call JSON object.",
        "expect": "json_tool_call",
    },
]


WEATHER_SENSORS_MCP_PROBES = [
    {
        "prompt": "Get the latest weather data for station DLU-123. Respond ONLY with a tool_call JSON object.",
        "expect": "json_tool_call",
        "expected_tool": "get_devices_by_name",
        "required_args": ["dluName", "detail", "grpId"],
        "strict_tool_call": True,
    },
    {
        "prompt": "Show rainfall measurements for device 1234 between 20240301000000 and 20240303235959 as CSV. Respond ONLY with a tool_call JSON object.",
        "expect": "json_tool_call",
        "expected_tool": "get_csv_measurement_data",
        "required_any_args": [["dlu_id", "dluId"]],
        "required_args": ["fromDate", "toDate", "channels"],
        "strict_tool_call": True,
    },
    {
        "prompt": "Give me a 12 hour forecast for coordinates 52.52, 13.405. Respond ONLY with a tool_call JSON object.",
        "expect": "json_tool_call",
        "expected_tool": "get_weather_forecast",
        "required_args": ["lat", "lng", "hours"],
        "strict_tool_call": True,
    },
    {
        "prompt": "Tool result for the previous call:\n{\"server_datetime\": \"2026-05-20 14:30:00\"}\nOriginal request: What is the current server time?\nAnswer with the result only. No suggestions. No follow-up questions.",
        "expect": "final_answer_only",
        "expected_substrings": ["2026-05-20 14:30:00"],
        "forbid_phrases": ["if you'd like", "i can", "let me know", "would you like", "could also", "you can also", "next step"],
        "max_words": 10,
    },
]


PROBE_PROFILES = {
    "default": DEFAULT_PROBES,
    "weathersensorsmcp": WEATHER_SENSORS_MCP_PROBES,
    "weathersensorsmcp_text_tool_call": WEATHER_SENSORS_MCP_PROBES,
}


@dataclass
class ProbeResult:
    prompt: str
    output: str
    ok: bool
    reasons: list[str]


def _run_ollama_via_api(
    model: str,
    prompt: str,
    timeout_sec: int,
    num_predict: int,
    num_ctx: int,
    system_prompt: str = "",
) -> str:
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": num_predict,
            "num_ctx": num_ctx,
            "temperature": 0.0,
            "top_p": 0.1,
        },
    }
    if system_prompt:
        payload["system"] = system_prompt
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            body = ""
        detail = body[:400] if body else str(exc)
        raise RuntimeError(f"ollama API HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"ollama API request failed: {exc}") from exc

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ollama API returned invalid JSON: {raw[:300]}") from exc

    out = str(decoded.get("response", "")).strip()
    if not out:
        raise RuntimeError("ollama API returned empty response")
    return out


def _run_ollama_chat_via_api(
    model: str,
    prompt: str,
    tools: list[dict[str, Any]],
    timeout_sec: int,
    num_predict: int,
    num_ctx: int,
    system_prompt: str = "",
) -> dict[str, Any]:
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": model,
        "messages": messages,
        "tools": tools,
        "stream": False,
        "options": {
            "num_predict": num_predict,
            "num_ctx": num_ctx,
            "temperature": 0.0,
            "top_p": 0.1,
        },
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            body = ""
        detail = body[:400] if body else str(exc)
        raise RuntimeError(f"ollama chat API HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"ollama chat API request failed: {exc}") from exc

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ollama chat API returned invalid JSON: {raw[:300]}") from exc

    message = decoded.get("message")
    if not isinstance(message, dict):
        raise RuntimeError("ollama chat API returned no assistant message")
    return message


def _run_ollama_via_cli(ollama_bin: str, model: str, prompt: str, timeout_sec: int) -> str:
    proc = subprocess.run(
        [ollama_bin, "run", model, prompt],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout_sec,
        check=False,
    )
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    if proc.returncode != 0:
        raise RuntimeError(f"ollama run failed ({proc.returncode}): {err[:300]}")
    if not out:
        raise RuntimeError("ollama returned empty output")
    return out


def _run_ollama(
    ollama_bin: str,
    model: str,
    prompt: str,
    timeout_sec: int,
    num_predict: int,
    num_ctx: int,
    system_prompt: str = "",
) -> str:
    try:
        return _run_ollama_via_api(
            model=model,
            prompt=prompt,
            timeout_sec=timeout_sec,
            num_predict=num_predict,
            num_ctx=num_ctx,
            system_prompt=system_prompt,
        )
    except RuntimeError as exc:
        msg = str(exc).lower()
        if "request failed" not in msg and "connection" not in msg and "refused" not in msg:
            raise
        # CLI fallback does not easily support system prompt override, but is kept for compatibility
        return _run_ollama_via_cli(ollama_bin=ollama_bin, model=model, prompt=prompt, timeout_sec=timeout_sec)


def _run_ollama_with_retries(
    ollama_bin: str,
    model: str,
    prompt: str,
    timeout_sec: int,
    num_predict: int,
    num_ctx: int,
    retries: int,
    system_prompt: str = "",
) -> str:
    last_error: Exception | None = None
    cur_predict = num_predict
    cur_ctx = num_ctx
    for attempt in range(1, retries + 1):
        try:
            return _run_ollama(
                ollama_bin=ollama_bin,
                model=model,
                prompt=prompt,
                timeout_sec=timeout_sec,
                num_predict=cur_predict,
                num_ctx=cur_ctx,
                system_prompt=system_prompt,
            )
        except Exception as exc:
            last_error = exc
            msg = str(exc).lower()
            if (
                "http 500" in msg
                or "resource limitation" in msg
                or "runner has unexpectedly stopped" in msg
            ):
                cur_predict = max(32, cur_predict // 2)
                cur_ctx = max(512, cur_ctx // 2)
            if attempt >= retries:
                break
            time.sleep(min(1.5 * attempt, 4.0))

    raise RuntimeError(f"probe failed after {retries} attempt(s): {last_error}")


def _run_ollama_chat_with_retries(
    model: str,
    prompt: str,
    tools: list[dict[str, Any]],
    timeout_sec: int,
    num_predict: int,
    num_ctx: int,
    retries: int,
    system_prompt: str = "",
) -> dict[str, Any]:
    last_error: Exception | None = None
    cur_predict = num_predict
    cur_ctx = num_ctx
    for attempt in range(1, retries + 1):
        try:
            return _run_ollama_chat_via_api(
                model=model,
                prompt=prompt,
                tools=tools,
                timeout_sec=timeout_sec,
                num_predict=cur_predict,
                num_ctx=cur_ctx,
                system_prompt=system_prompt,
            )
        except Exception as exc:
            last_error = exc
            msg = str(exc).lower()
            if (
                "http 500" in msg
                or "resource limitation" in msg
                or "runner has unexpectedly stopped" in msg
            ):
                cur_predict = max(32, cur_predict // 2)
                cur_ctx = max(512, cur_ctx // 2)
            if attempt >= retries:
                break
            time.sleep(min(1.5 * attempt, 4.0))

    raise RuntimeError(f"native chat probe failed after {retries} attempt(s): {last_error}")


def _tokenize(text: str) -> list[str]:
    return re.findall(r"[A-Za-z0-9_]+", text.lower())


def _max_consecutive_run(tokens: list[str]) -> int:
    if not tokens:
        return 0
    max_run = 1
    cur = 1
    for idx in range(1, len(tokens)):
        if tokens[idx] == tokens[idx - 1]:
            cur += 1
            max_run = max(max_run, cur)
        else:
            cur = 1
    return max_run


def _looks_degenerated(text: str) -> list[str]:
    reasons: list[str] = []
    stripped = text.strip()
    tokens = _tokenize(stripped)

    if len(stripped) < 24:
        reasons.append("output_too_short")
        return reasons

    if re.search(r"(ipi){3,}", stripped.lower()):
        reasons.append("ipi_loop_pattern")

    if len(tokens) >= 20:
        unique_ratio = len(set(tokens)) / len(tokens)
        if unique_ratio < 0.18:
            reasons.append(f"low_unique_token_ratio:{unique_ratio:.3f}")

        most_common = max((tokens.count(token) for token in set(tokens)), default=0)
        top_fraction = most_common / len(tokens)
        if top_fraction > 0.22:
            reasons.append(f"dominant_token_fraction:{top_fraction:.3f}")

        max_run = _max_consecutive_run(tokens)
        if max_run > 7:
            reasons.append(f"long_repeated_run:{max_run}")

    if re.search(r"(.)\1{7,}", stripped):
        reasons.append("long_repeated_char_run")

    return reasons


def _repair_and_parse_json(json_str: str) -> Any:
    cleaned = json_str.strip()
    if not cleaned:
        return None
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass

    # Try balancing braces/brackets by appending potential close structures
    for suffix in ["}", '"}', '"} }', '"} } }', ']', ']}', ']} }']:
        try:
            return json.loads(cleaned + suffix)
        except json.JSONDecodeError:
            continue

    # Try stripping incomplete trailing attributes (e.g. , "key": or , "key": "value)
    # Truncate at the last comma and try to close it
    last_comma = cleaned.rfind(",")
    if last_comma != -1:
        truncated = cleaned[:last_comma].strip()
        for suffix in ["}", '"}', '"} }', ']', ']}', ']} }']:
            try:
                return json.loads(truncated + suffix)
            except json.JSONDecodeError:
                continue

    # Try to find the first '{' and matching '}'
    brace_match = re.search(r"(\{.*\})", cleaned, flags=re.DOTALL)
    if brace_match:
        try:
            return json.loads(brace_match.group(1))
        except json.JSONDecodeError:
            pass

    return None


def _try_parse_first_json_object(text: str) -> dict[str, Any] | None:
    stripped = text.strip()
    if not stripped.startswith("{"):
        # Let's try to repair it anyway if it contains '{'
        start_idx = stripped.find("{")
        if start_idx != -1:
            stripped = stripped[start_idx:]
        else:
            return None
    depth = 0
    in_string = False
    escape_next = False
    for idx, ch in enumerate(stripped):
        if escape_next:
            escape_next = False
            continue
        if ch == "\\" and in_string:
            escape_next = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                candidate = stripped[: idx + 1]
                try:
                    parsed = json.loads(candidate)
                except json.JSONDecodeError:
                    return None
                return parsed if isinstance(parsed, dict) else None
    
    # Try general repair if it didn't find matching braces
    parsed = _repair_and_parse_json(stripped)
    return parsed if isinstance(parsed, dict) else None


def _extract_tool_call_payload(text: str) -> tuple[dict[str, Any] | None, str | None, str | None]:
    payload = None
    matched_prefix = None

    # 1. Check for Mistral [TOOL_CALLS] control token format with JSON array
    tool_calls_match = re.search(r"\[TOOL_CALLS\]\s*(\[.*\])", text, flags=re.DOTALL)
    if tool_calls_match:
        raw = tool_calls_match.group(1).strip()
        matched_prefix = "[TOOL_CALLS]"
        calls = _repair_and_parse_json(raw)
        if isinstance(calls, list) and len(calls) > 0:
            first_call = calls[0]
            if isinstance(first_call, dict):
                name = first_call.get("name")
                args = first_call.get("arguments")
                payload = {"name": name, "arguments": args}

    # 2. Check for Mistral [TOOL_CALLS]tool_name[ARGS]{...} format (or raw tool_name[ARGS]{...})
    if payload is None:
        mistral_match = re.search(r"(?:\[TOOL_CALLS\])?\s*([a-zA-Z0-9_]+)\s*\[ARGS\]\s*(\{.*)$", text.strip(), flags=re.DOTALL)
        if mistral_match:
            tool_name = mistral_match.group(1)
            json_str = mistral_match.group(2).strip()
            if json_str.endswith("[/TOOL_CALLS]"):
                json_str = json_str[:-13].strip()
            args = _repair_and_parse_json(json_str)
            if isinstance(args, dict):
                payload = {"name": tool_name, "arguments": args}

    # 3. Check for backtick format: `tool_name` `{"arg": "val"}`
    if payload is None:
        backtick_match = re.search(r"`([a-zA-Z0-9_]+)`\s*`?(\{.*)$", text.strip(), flags=re.DOTALL)
        if backtick_match:
            tool_name = backtick_match.group(1)
            json_str = backtick_match.group(2).strip()
            if json_str.endswith("`"):
                json_str = json_str[:-1].strip()
            args = _repair_and_parse_json(json_str)
            if isinstance(args, dict):
                payload = {"name": tool_name, "arguments": args}

    # 4. Check for function-like syntax: tool_name({"arg": "val"})
    if payload is None:
        func_match = re.search(r"\b([a-zA-Z0-9_]+)\s*\((.*)\)\s*$", text.strip(), flags=re.DOTALL)
        if func_match:
            tool_name = func_match.group(1)
            json_str = func_match.group(2).strip()
            args = _repair_and_parse_json(json_str)
            if isinstance(args, dict):
                payload = {"name": tool_name, "arguments": args}

    if payload is None:
        match = re.search(r"tool_call\s*:\s*(\{.*\})", text, flags=re.IGNORECASE | re.DOTALL)
        if match:
            raw = match.group(1).strip()
            matched_prefix = match.group(0)
            payload = _repair_and_parse_json(raw)
            if payload is None:
                return None, "invalid_tool_call_json", None
        else:
            payload = _try_parse_first_json_object(text.strip())
            if payload is None:
                word_match = re.search(r"\b\w[\w_]*\s*:\s*\{", text)
                if word_match:
                    json_start = word_match.end() - 1
                    payload = _try_parse_first_json_object(text[json_start:])
            if payload is None:
                cleaned_text = text.strip().replace("</tool_call>", "").strip()
                payload = _repair_and_parse_json(cleaned_text)
            if payload is None:
                return None, "missing_tool_call_prefix", None

    if not isinstance(payload, dict):
        return None, "tool_call_not_object", matched_prefix

    if "tool_calls" not in payload and "message" in payload and isinstance(payload["message"], dict):
        payload = payload["message"]

    if isinstance(payload.get("content"), str) and payload["content"].strip():
        inner_content = payload["content"].strip().replace("</tool_call>", "").strip()
        parsed_inner = _try_parse_first_json_object(inner_content)
        if isinstance(parsed_inner, dict):
            payload = parsed_inner

    native_tool_calls = payload.get("tool_calls")
    if isinstance(native_tool_calls, list) and native_tool_calls:
        first_call = native_tool_calls[0]
        if not isinstance(first_call, dict):
            return None, "native_tool_call_not_object", matched_prefix
        function_block = first_call.get("function") if isinstance(first_call.get("function"), dict) else first_call
        name = function_block.get("name")
        args = function_block.get("arguments")
        if isinstance(args, str):
            args = _repair_and_parse_json(args)
            if args is None:
                return None, "native_tool_call_invalid_arguments", matched_prefix
        normalized_payload = {"name": name, "arguments": args}
        payload = normalized_payload

    name = payload.get("name")
    args = payload.get("arguments")

    if not isinstance(name, str) or not name.strip():
        for alt_key in ("tool", "tool_name", "function"):
            if isinstance(payload.get(alt_key), str) and payload[alt_key].strip():
                name = payload[alt_key]
                break

    if args is None:
        for alt_key in ("args", "tool_input", "input", "params", "parameters"):
            if alt_key in payload:
                val = payload.get(alt_key)
                if isinstance(val, dict):
                    args = val
                    break
        if args is None:
            args = {}

    if not isinstance(name, str) or not name.strip():
        return None, "tool_call_missing_name", matched_prefix
    if not isinstance(args, dict):
        return None, "tool_call_missing_arguments", matched_prefix

    # Return normalized payload to ensure constraints checking succeeds
    normalized_payload = {"name": name, "arguments": args}
    return normalized_payload, None, matched_prefix


def _evaluate_tool_call_constraints(spec: dict[str, Any], payload: dict[str, Any]) -> list[str]:
    reasons: list[str] = []

    expected_tool = spec.get("expected_tool")
    if isinstance(expected_tool, str):
        tool_name = payload.get("name")
        if tool_name != expected_tool:
            reasons.append(f"wrong_tool:{tool_name}")

    arguments = payload.get("arguments")
    if not isinstance(arguments, dict):
        return reasons

    required_args = spec.get("required_args")
    if isinstance(required_args, list):
        for arg_name in required_args:
            if isinstance(arg_name, str) and arg_name not in arguments:
                reasons.append(f"missing_arg:{arg_name}")

    required_any_args = spec.get("required_any_args")
    if isinstance(required_any_args, list):
        for arg_group in required_any_args:
            if not isinstance(arg_group, list):
                continue
            if not any(isinstance(arg_name, str) and arg_name in arguments for arg_name in arg_group):
                reasons.append("missing_any_arg:" + "|".join(str(arg_name) for arg_name in arg_group))

    return reasons


def _has_extra_text_around_tool_call(text: str) -> bool:
    stripped = text.strip()
    if stripped.startswith("tool_call:"):
        match = re.match(r"tool_call\s*:\s*(\{.*\})\s*$", stripped, flags=re.IGNORECASE | re.DOTALL)
        return match is None
    if not stripped.startswith("{"):
        return True
    depth = 0
    in_string = False
    escape_next = False
    for idx, ch in enumerate(stripped):
        if escape_next:
            escape_next = False
            continue
        if ch == "\\" and in_string:
            escape_next = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                trailing = stripped[idx + 1 :].strip()
                return trailing != ""
    return False


def _evaluate_output(text: str, spec: dict[str, Any]) -> list[str]:
    expect = str(spec.get("expect", "free_text"))
    reasons = _looks_degenerated(text)
    if expect == "json_tool_call":
        payload, err, _ = _extract_tool_call_payload(text)
        if err is not None:
            reasons.append(err)
        elif isinstance(payload, dict):
            reasons.extend(_evaluate_tool_call_constraints(spec, payload))
            if bool(spec.get("strict_tool_call")) and _has_extra_text_around_tool_call(text):
                reasons.append("extra_text_around_tool_call")
            reasons = [
                reason
                for reason in reasons
                if reason == "ipi_loop_pattern"
                or reason.startswith("wrong_tool:")
                or reason.startswith("missing_arg:")
                or reason.startswith("missing_any_arg:")
                or reason == "extra_text_around_tool_call"
            ]
    elif expect == "ollama_native_tool_call":
        payload, err, _ = _extract_tool_call_payload(text)
        if err is not None:
            reasons.append(err)
        elif isinstance(payload, dict):
            reasons.extend(_evaluate_tool_call_constraints(spec, payload))
            reasons = [
                reason
                for reason in reasons
                if reason == "ipi_loop_pattern"
                or reason.startswith("wrong_tool:")
                or reason.startswith("missing_arg:")
                or reason.startswith("missing_any_arg:")
            ]
    elif expect == "free_text":
        if "tool_call:" in text.lower():
             reasons.append("unexpected_tool_call")
    elif expect == "final_answer_only":
        lowered = text.lower()
        if "tool_call:" in lowered:
            reasons.append("unexpected_tool_call")
        expected_substrings = spec.get("expected_substrings")
        if isinstance(expected_substrings, list):
            for substring in expected_substrings:
                if isinstance(substring, str) and substring not in text:
                    reasons.append(f"missing_expected_text:{substring}")
        forbid_phrases = spec.get("forbid_phrases")
        if isinstance(forbid_phrases, list):
            for phrase in forbid_phrases:
                if isinstance(phrase, str) and phrase.lower() in lowered:
                    reasons.append(f"forbidden_phrase:{phrase}")
        max_words = spec.get("max_words")
        if isinstance(max_words, int) and len(_tokenize(text)) > max_words:
            reasons.append(f"answer_too_long:{len(_tokenize(text))}")
        all_substrings_found = not any(reason.startswith("missing_expected_text:") for reason in reasons)
        reasons = [
            reason
            for reason in reasons
            if not reason.startswith("low_unique_token_ratio")
            and not reason.startswith("dominant_token_fraction")
            and not (reason == "output_too_short" and all_substrings_found)
        ]
    return reasons


def _load_profile_from_file(profile_file: str) -> list[dict[str, Any]]:
    with open(profile_file, encoding="utf-8") as handle:
        payload = json.load(handle)

    if isinstance(payload, list):
        probes = payload
    elif isinstance(payload, dict) and isinstance(payload.get("probes"), list):
        probes = payload["probes"]
    else:
        raise RuntimeError(f"profile file must contain a probe list or a {{\"probes\": [...]}} object: {profile_file}")

    normalized: list[dict[str, Any]] = []
    for item in probes:
        if not isinstance(item, dict) or not isinstance(item.get("prompt"), str):
            raise RuntimeError(f"invalid probe entry in profile file: {profile_file}")
        normalized.append(item)
    return normalized


def get_probe_profile(profile: str, profile_file: str | None = None) -> list[dict[str, Any]]:
    if profile_file:
        return _load_profile_from_file(profile_file)
    normalized = profile.strip().lower()
    return PROBE_PROFILES.get(normalized, DEFAULT_PROBES)


def run_gate(
    ollama_bin: str,
    model: str,
    timeout_sec: int,
    num_predict: int,
    num_ctx: int,
    retries: int,
    profile: str,
    profile_file: str | None = None,
    system_prompt: str = "",
    force_generate: bool = False,
) -> list[ProbeResult]:
    results: list[ProbeResult] = []
    for spec in get_probe_profile(profile, profile_file=profile_file):
        prompt = str(spec["prompt"])
        expect = str(spec.get("expect", "free_text"))
        if expect == "ollama_native_tool_call" and not force_generate:
            raw_tools = spec.get("tools")
            if not isinstance(raw_tools, list) or not raw_tools:
                raise RuntimeError("native tool-call probes require a non-empty 'tools' list in the profile")
            message = _run_ollama_chat_with_retries(
                model=model,
                prompt=prompt,
                tools=raw_tools,
                timeout_sec=timeout_sec,
                num_predict=num_predict,
                num_ctx=num_ctx,
                retries=retries,
                system_prompt=system_prompt,
            )
            output = json.dumps(message, ensure_ascii=False)
        else:
            effective_system_prompt = system_prompt
            if expect == "ollama_native_tool_call" and force_generate:
                raw_tools = spec.get("tools")
                if isinstance(raw_tools, list) and raw_tools:
                    # Inject tools in the format the model (Mistral) expects
                    tools_json = json.dumps(raw_tools, ensure_ascii=False)
                    effective_system_prompt = f"[AVAILABLE_TOOLS] {tools_json} [/AVAILABLE_TOOLS]\n{system_prompt}"
            output = _run_ollama_with_retries(
                ollama_bin=ollama_bin,
                model=model,
                prompt=prompt,
                timeout_sec=timeout_sec,
                num_predict=num_predict,
                num_ctx=num_ctx,
                retries=retries,
                system_prompt=effective_system_prompt,
            )
        reasons = _evaluate_output(output, spec)
        results.append(ProbeResult(prompt=prompt, output=output, ok=len(reasons) == 0, reasons=reasons))
    return results


def _default_pass_threshold(profile: str, profile_file: str | None) -> float:
    if profile_file:
        return 0.75
    return 0.75 if profile.strip().lower() in {"weathersensorsmcp", "weathersensorsmcp_text_tool_call"} else 0.30


def main() -> None:
    parser = argparse.ArgumentParser(description="Run local quality gate probes on a trained Ollama model")
    parser.add_argument("--model", required=True, help="Ollama model name")
    parser.add_argument("--ollama-bin", default="ollama", help="Path to ollama executable")
    parser.add_argument("--timeout", type=int, default=120, help="Timeout per probe in seconds")
    parser.add_argument("--num-predict", type=int, default=128, help="Maximum tokens generated per probe")
    parser.add_argument("--num-ctx", type=int, default=1024, help="Context window used for each probe")
    parser.add_argument("--retries", type=int, default=3, help="Retries per probe for transient local runtime errors")
    parser.add_argument("--profile", default="default", help="Probe profile name (for example: default, weathersensorsmcp)")
    parser.add_argument("--profile-file", default="", help="Optional JSON file describing the probes for this contract")
    parser.add_argument("--system-prompt-file", default="", help="Optional path to system prompt file to load")
    parser.add_argument(
        "--pass-threshold",
        type=float,
        default=-1.0,
        help="Minimum fraction of probes that must pass. Use a negative value to pick the profile default.",
    )
    parser.add_argument(
        "--force-generate",
        action="store_true",
        help="Force using /api/generate instead of /api/chat, bypassing Ollama tool-support capability checks.",
    )
    args = parser.parse_args()

    profile_file = args.profile_file.strip() or None
    if profile_file is not None:
        profile_file = str(Path(profile_file).expanduser())

    system_prompt = ""
    system_prompt_file = args.system_prompt_file.strip()
    if system_prompt_file:
        system_prompt_file_path = Path(system_prompt_file).expanduser()
        if system_prompt_file_path.is_file():
            system_prompt = system_prompt_file_path.read_text(encoding="utf-8").strip()
            print(f"[QUALITY GATE] Loaded system prompt from: {system_prompt_file_path}")

    if args.pass_threshold < 0:
        args.pass_threshold = _default_pass_threshold(args.profile, profile_file)

    try:
        results = run_gate(
            args.ollama_bin,
            args.model,
            args.timeout,
            args.num_predict,
            args.num_ctx,
            args.retries,
            args.profile,
            profile_file=profile_file,
            system_prompt=system_prompt,
            force_generate=args.force_generate,
        )
    except Exception as exc:
        print(f"[QUALITY GATE] ERROR: {exc}")
        sys.exit(2)

    failed = [result for result in results if not result.ok]
    pass_rate = (len(results) - len(failed)) / len(results) if results else 0.0

    print("[QUALITY GATE] Probe summary:")
    for idx, result in enumerate(results, start=1):
        status = "PASS" if result.ok else "FAIL"
        preview = result.output.replace("\n", " ")[:180]
        print(f"  {idx}. {status} | prompt={result.prompt}")
        print(f"     output={preview}")
        if result.reasons:
            print(f"     reasons={', '.join(result.reasons)}")

    if pass_rate < args.pass_threshold:
        print(
            f"[QUALITY GATE] FAILED: {len(failed)}/{len(results)} probe(s) indicate degeneration "
            f"(pass rate {pass_rate:.0%} < threshold {args.pass_threshold:.0%})."
        )
        sys.exit(1)

    print(f"[QUALITY GATE] PASSED ({len(results) - len(failed)}/{len(results)} probes OK)")


if __name__ == "__main__":
    main()
