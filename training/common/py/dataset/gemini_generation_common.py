from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path


TEXT_TOOL_CALL_CONTRACT = "text_tool_call"
OLLAMA_NATIVE_CONTRACT = "ollama_native"
EXAMPLE_GEN_PROVIDER_GEMINI = "gemini"
EXAMPLE_GEN_PROVIDER_DEEPSEEK = "deepseek"
EXAMPLE_GEN_PROVIDER_OPENAI_COMPAT = "openai_compatible"


def install_hint() -> str:
    python_exe = Path(sys.executable)
    if python_exe.exists():
        return f'"{python_exe}" -m pip install google-genai'
    return "python -m pip install google-genai"


def _normalize_example_gen_provider(provider: str | None) -> str:
    normalized = (provider or EXAMPLE_GEN_PROVIDER_DEEPSEEK).strip().lower()
    return normalized or EXAMPLE_GEN_PROVIDER_DEEPSEEK


def _example_gen_model_default(provider: str) -> str:
    if provider == EXAMPLE_GEN_PROVIDER_GEMINI:
        return "gemini-2.5-pro"
    if provider == EXAMPLE_GEN_PROVIDER_DEEPSEEK:
        return "deepseek-v4-pro"
    return "deepseek-v4-pro"


def resolve_example_gen_config(model_name: str | None = None) -> dict[str, str]:
    provider = _normalize_example_gen_provider(os.getenv("EXAMPLE_GEN_PROVIDER"))
    resolved_model = (model_name or os.getenv("EXAMPLE_GEN_MODEL") or "").strip()
    if not resolved_model:
        resolved_model = _example_gen_model_default(provider)

    if provider == EXAMPLE_GEN_PROVIDER_GEMINI:
        return {
            "provider": provider,
            "api_key": require_env("GEMINI_API_KEY"),
            "model": resolved_model,
            "base_url": "",
        }

    if provider == EXAMPLE_GEN_PROVIDER_DEEPSEEK:
        return {
            "provider": provider,
            "api_key": require_env("DEEPSEEK_API_KEY"),
            "model": resolved_model,
            "base_url": os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1").strip() or "https://api.deepseek.com/v1",
        }

    if provider == EXAMPLE_GEN_PROVIDER_OPENAI_COMPAT:
        return {
            "provider": provider,
            "api_key": require_env("EXAMPLE_GEN_API_KEY"),
            "model": resolved_model,
            "base_url": require_env("EXAMPLE_GEN_BASE_URL"),
        }

    raise SystemExit(
        "Unsupported EXAMPLE_GEN_PROVIDER. Use one of: gemini, deepseek, openai_compatible"
    )


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def strip_markdown_fences(text: str) -> str:
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json|jsonl)?\s*", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    return cleaned.strip()


def normalize_contract_type(contract_type: str | None) -> str:
    normalized = (contract_type or TEXT_TOOL_CALL_CONTRACT).strip().lower()
    return normalized or TEXT_TOOL_CALL_CONTRACT


def extract_balanced_json(text: str, start_index: int) -> str:
    if start_index < 0 or start_index >= len(text) or text[start_index] != "{":
        return ""

    depth = 0
    in_string = False
    escaped = False
    for index in range(start_index, len(text)):
        char = text[index]
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start_index : index + 1]
    return ""


def normalize_tool_call_content(content: str) -> str:
    marker = "tool_call:"
    raw = content.strip()
    if not raw.startswith(marker):
        return raw

    payload_text = raw[len(marker) :].strip()
    first_brace = payload_text.find("{")
    if first_brace < 0:
        return raw

    balanced = extract_balanced_json(payload_text, first_brace)
    if not balanced:
        return raw

    try:
        payload = json.loads(balanced)
    except Exception:
        return raw

    if isinstance(payload, dict) and isinstance(payload.get("tool_call"), dict):
        payload = payload["tool_call"]

    if not isinstance(payload, dict):
        return raw

    name = payload.get("name")
    if not isinstance(name, str) or not name.strip():
        return raw

    args = payload.get("arguments")
    if not isinstance(args, dict):
        params = payload.get("parameters")
        if isinstance(params, dict):
            args = params
        else:
            args = {}

    normalized = {"name": name.strip(), "arguments": args}
    return f"tool_call: {json.dumps(normalized, ensure_ascii=False)}"


def _parse_json_object(value: object) -> dict | None:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None
    return None


def _payload_from_text_content(content: object) -> dict | None:
    if not isinstance(content, str) or not content.startswith("tool_call: "):
        return None

    payload = _parse_json_object(content[len("tool_call: ") :])
    if not isinstance(payload, dict):
        return None

    name = payload.get("name")
    arguments = payload.get("arguments")
    parameters = payload.get("parameters")
    if not isinstance(name, str) or not name.strip():
        return None
    if not isinstance(arguments, dict):
        if isinstance(parameters, dict):
            arguments = parameters
        else:
            return None

    return {"name": name.strip(), "arguments": arguments}


def _payload_from_native_tool_calls(tool_calls: object) -> dict | None:
    if not isinstance(tool_calls, list) or not tool_calls:
        return None

    first_call = tool_calls[0]
    if not isinstance(first_call, dict):
        return None

    function_block = first_call.get("function") if isinstance(first_call.get("function"), dict) else first_call
    name = function_block.get("name")
    arguments = function_block.get("arguments")
    if not isinstance(name, str) or not name.strip():
        return None

    parsed_arguments = _parse_json_object(arguments)
    if not isinstance(parsed_arguments, dict):
        return None

    return {"name": name.strip(), "arguments": parsed_arguments}


def build_native_tool_call(payload: dict) -> dict:
    return {
        "function": {
            "name": payload["name"],
            "arguments": payload["arguments"],
        }
    }


def extract_tool_payload_from_assistant(assistant: object, contract_type: str = TEXT_TOOL_CALL_CONTRACT) -> dict | None:
    if not isinstance(assistant, dict):
        return None

    normalized_contract = normalize_contract_type(contract_type)
    if normalized_contract == OLLAMA_NATIVE_CONTRACT:
        payload = _payload_from_native_tool_calls(assistant.get("tool_calls"))
        if payload is not None:
            return payload
        return _payload_from_text_content(assistant.get("content"))

    return _payload_from_text_content(assistant.get("content"))


def extract_tool_payload(row: dict, contract_type: str = TEXT_TOOL_CALL_CONTRACT) -> dict | None:
    messages = row.get("messages")
    if not isinstance(messages, list):
        return None

    assistant = next((message for message in messages if isinstance(message, dict) and message.get("role") == "assistant"), None)
    return extract_tool_payload_from_assistant(assistant, contract_type)


def coerce_value_for_schema(value: object, schema: dict) -> object:
    if not isinstance(schema, dict):
        return value

    schema_type = schema.get("type")
    if schema_type == "string" and isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    if schema_type == "number" and isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return value
    if schema_type == "integer" and isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return value
    if schema_type == "boolean" and isinstance(value, str):
        lowered = value.strip().lower()
        if lowered == "true":
            return True
        if lowered == "false":
            return False
    return value


def normalize_payload_arguments(payload: dict, tools_schema: dict[str, dict]) -> dict:
    if not isinstance(payload, dict):
        return payload

    name = payload.get("name")
    if not isinstance(name, str):
        return payload

    arguments = payload.get("arguments")
    if not isinstance(arguments, dict):
        return payload

    schema = tools_schema.get(name)
    if not isinstance(schema, dict):
        return payload

    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        return payload

    payload["arguments"] = {
        key: coerce_value_for_schema(value, properties.get(key, {}))
        for key, value in arguments.items()
    }
    return payload


def normalize_training_row(
    row: dict,
    tools_schema: dict[str, dict],
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
) -> dict:
    messages = row.get("messages")
    if not isinstance(messages, list):
        return row

    normalized_contract = normalize_contract_type(contract_type)
    for message in messages:
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        payload = extract_tool_payload_from_assistant(message, normalized_contract)
        if payload is None:
            content = message.get("content")
            if isinstance(content, str):
                normalized_content = normalize_tool_call_content(content)
                payload = _payload_from_text_content(normalized_content)
                if normalized_contract == TEXT_TOOL_CALL_CONTRACT:
                    message["content"] = normalized_content
        if payload is not None:
            payload = normalize_payload_arguments(payload, tools_schema)
            if normalized_contract == OLLAMA_NATIVE_CONTRACT:
                message["content"] = ""
                message["tool_calls"] = [build_native_tool_call(payload)]
            else:
                message["content"] = f"tool_call: {json.dumps(payload, ensure_ascii=False)}"
        break

    return row


def has_parseable_tool_call(row: dict, contract_type: str = TEXT_TOOL_CALL_CONTRACT) -> bool:
    messages = row.get("messages")
    if not isinstance(messages, list):
        return False

    assistant = next((message for message in messages if isinstance(message, dict) and message.get("role") == "assistant"), None)
    payload = extract_tool_payload_from_assistant(assistant, contract_type)
    if not isinstance(payload, dict):
        return False

    name = payload.get("name")
    args = payload.get("arguments")
    return isinstance(name, str) and bool(name) and isinstance(args, dict)


def row_has_schema_errors(
    row: dict,
    tools_schema: dict[str, dict],
    validate_tool_parameters,
    contract_type: str = TEXT_TOOL_CALL_CONTRACT,
) -> bool:
    messages = row.get("messages")
    if not isinstance(messages, list) or len(messages) < 2:
        return True

    assistant = next((message for message in messages if isinstance(message, dict) and message.get("role") == "assistant"), None)
    if not isinstance(assistant, dict):
        return True

    payload = extract_tool_payload_from_assistant(assistant, contract_type)
    if not isinstance(payload, dict):
        return True

    tool_name = payload.get("name")
    tool_args = payload.get("arguments")
    if not isinstance(tool_name, str) or not tool_name:
        return True
    if not isinstance(tool_args, dict):
        return True

    if tool_name == "no_tool":
        return "reason" not in tool_args
    if tool_name not in tools_schema:
        return True
    return bool(validate_tool_parameters(tool_name, tool_args, tools_schema[tool_name]))


def _extract_openai_compatible_text(payload: dict) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list):
        raise SystemExit("Example generator returned no choices.")

    for choice in choices:
        if not isinstance(choice, dict):
            continue
        message = choice.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return strip_markdown_fences(content)

    raise SystemExit("Example generator returned no text content.")


def generate_with_openai_compatible(
    api_key: str,
    base_url: str,
    model_name: str,
    prompt: str,
    *,
    temperature: float,
    top_p: float,
) -> str:
    request_payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
        "top_p": top_p,
        "stream": False,
    }

    base = base_url.rstrip("/")
    request = urllib.request.Request(
        url=f"{base}/chat/completions",
        data=json.dumps(request_payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            response_payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Example generator HTTP error {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Example generator request failed: {exc}") from exc

    return _extract_openai_compatible_text(response_payload)


def generate_with_gemini(api_key: str, model_name: str, prompt: str, *, temperature: float, top_p: float) -> str:
    try:
        from google import genai
        from google.genai import types
    except ImportError as exc:
        raise SystemExit(
            f"google-genai is not installed: {exc}\n"
            f"Install with: {install_hint()}"
        )

    client = genai.Client(api_key=api_key)
    response = client.models.generate_content(
        model=model_name,
        contents=prompt,
        config=types.GenerateContentConfig(
            temperature=temperature,
            top_p=top_p,
            max_output_tokens=65535,
        ),
    )

    text = getattr(response, "text", None)
    if not text:
        candidates = getattr(response, "candidates", None) or []
        for candidate in candidates:
            content = getattr(candidate, "content", None)
            parts = getattr(content, "parts", None) or []
            merged = "".join(getattr(part, "text", "") for part in parts)
            if merged.strip():
                text = merged
                break

    if not text:
        raise SystemExit("Gemini returned an empty response text.")
    return strip_markdown_fences(text)


def generate_with_example_model(model_name: str, prompt: str, *, temperature: float, top_p: float) -> str:
    config = resolve_example_gen_config(model_name)
    provider = config["provider"]
    if provider == EXAMPLE_GEN_PROVIDER_GEMINI:
        return generate_with_gemini(
            api_key=config["api_key"],
            model_name=config["model"],
            prompt=prompt,
            temperature=temperature,
            top_p=top_p,
        )

    return generate_with_openai_compatible(
        api_key=config["api_key"],
        base_url=config["base_url"],
        model_name=config["model"],
        prompt=prompt,
        temperature=temperature,
        top_p=top_p,
    )