# Weather Sensors MCP Training Template

This file is the canonical prompt template for generating synthetic MCP tool-calling datasets for weather sensors.

Use it with:
- scripts_training/train.py --build-prompt
- scripts_training/generate_train_jsonl_gemini.py

The generated prompt should be written to:
- scripts_training/<scope>/mcp_out/<base-name>/generated_train_prompt.md

---

# Role: Weather Sensors MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for a small model that maps user requests to weather-sensor MCP tool calls.

## Input
- Tool schema file is injected below from the selected MCP schema path (for example: scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl)
- Use only tools from the provided schema.

## Objective
Create tool-calling JSONL lines for weather station and sensor workflows.

Each line must be exactly one JSON object in this format:

{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"TOOL_NAME\",\"arguments\":{...}}"}]}

## Hard Requirements
1. Output JSONL lines only. No comments. No markdown fences. No prose.
2. Assistant message must start with "tool_call: " followed by valid JSON.
3. Tool call JSON must contain:
   - name: string
   - arguments: object
4. Tool name must exist in the provided weather tool schema.
5. Argument keys must match selected tool schema keys.
6. Required parameters must be present.
7. Types must match schema definitions.
8. No trailing commas.
9. If no supported tool can satisfy the request, use:
   tool_call: {"name":"no_tool","arguments":{"reason":"short reason"}}
10. Keep `no_tool.arguments.reason` short and non-conversational. Avoid first-person wording and follow-up suggestions.
11. If a request can be solved by chaining supported tools, do not use `no_tool`.

## Dataset Size
Generate at least 300 examples.
Target 320-420 examples when possible.

## Composition Targets
- 70-80% positive tool calls (valid weather sensor requests)
- 20-30% negative examples (`no_tool`)

Positive examples should cover:
- device discovery, filtering, and lookup
- channel lookup and measurement retrieval
- csv/json/excel output variants
- relative and fixed date ranges
- chart/map/forecast style requests
- short prompts, conversational prompts, and multi-constraint prompts

Negative examples should include:
- unsupported domains (finance, social media, local OS control)
- requests requiring unavailable tools
- impossible/unsafe requests not covered by schema

Avoid negative examples that incorrectly reject requests which can be solved by lookup, time resolution, or multi-step tool chaining.

## Diversity Rules
- Avoid duplicate user prompts.
- Vary user style, language tone, and verbosity.
- Vary parameter values and optional argument usage.
- Include realistic domain operations that reflect how users would actually invoke the tools.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- Every `tool_call` payload parses as JSON.
- No unknown tool names.
- No invalid argument keys.
- Required arguments present.

## Final Output
Return raw JSONL only.
