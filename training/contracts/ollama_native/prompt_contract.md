# Role: Weather Sensors MCP Tool-Calling Dataset Generator (Ollama Native)

Generate high-quality JSONL training data for an Ollama-native tool-calling model.

## Input
- Tool schema file is injected below from the weather sensor configuration.
- Use only tools from the provided schema.

## Objective
Create native tool-calling JSONL lines for weather station and sensor workflows.

Each line must be exactly one JSON object in this format:

{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"TOOL_NAME","arguments":{...}}}]}]}

## Hard Requirements
1. Output JSONL only. No markdown fences. No comments. No prose.
2. Every assistant tool-call message must use empty string content: `"content": ""`.
3. Every assistant tool-call message must use the native `tool_calls` list with a `function` block containing `name` and `arguments`.
   Example format:
   `"tool_calls": [{"function": {"name": "TOOL_NAME", "arguments": {...}}}]`
4. Tool names must exist in the injected schema, except `no_tool` which is allowed as a fallback.
5. Argument keys and types must match the selected tool schema exactly. Do not invent arguments.
6. Required arguments must be present.
7. Never use legacy text wrappers like `tool_call: ...` in the content.
8. If a request is solvable by chaining current schema tools, do not use `no_tool`.
9. Do not generate plain-text follow-up answer rows in this dataset. Every example assistant row at the tool-calling phase must be a native tool call.
10. If no supported tool can satisfy the request, use the fallback `no_tool` call:
    `"tool_calls": [{"function": {"name": "no_tool", "arguments": {"reason": "short explanation of why it is not supported"}}}]`

## Parameter Constraints (STRICT)
- **`get_device`**: Does NOT support a `language` parameter. Do not include `language` in `get_device` arguments.
- **`get_device_configuration`**: Does NOT support a `language` parameter. Do not include `language`.
- **`get_measurement_data_in_chart` / `get_measurement_data_in_chart_by_name`**: Does NOT support `fileName` or `output_type` parameters. It supports `output` (e.g. `"png"`, `"pdf"`, `"excel"`), `chart_type`, and others listed in the schema. Do not generate `fileName` or `output_type`.
- **`get_weather_forecast`**: Does NOT support `grpId` or coordinates as strings. Ensure `lat` and `lng` are floating-point numbers.
- **`grpId`**: Default to `-1` unless a specific group is specified.
- **`detail`**: Default to `1` for device lookup/current data unless requested otherwise.
- **`channels`**: Must be a string (e.g. `"ALL"`, `"[ALL]"` or specific channel names). Never use `null`.

## Current-Schema Routing Policy
Teach these rules consistently:

1. Current/latest weather wording means ACTUAL DATA.
   - Phrases like "current weather", "latest weather", "aktuelle Wetterdaten", "current sensor values" must use `get_all_devices`, `get_devices_by_name`, `get_devices_around_position`, or `get_device` with `detail=1`.
   - Do not use measurement export tools unless a time range or historical request is explicit.

2. Historical/time-range requests use measurement tools.
   - Use `get_csv_measurement_data`, `get_json_measurement_data`, `get_excel_measurement_data`, or `get_measurement_data_in_chart` when the request is clearly historical.
   - If the station name is known, prefer the `*_by_name` variants directly instead of lookup-first patterns.

3. Relative time requires `get_server_datetime` first.
   - For prompts like "today", "yesterday", "last 6 hours", "this year", or "until now", the first tool call must be `get_server_datetime`.

4. Forecast requires coordinates.
   - Never call `get_weather_forecast` without both `lat` and `lng`.
   - If coordinates are not present, first resolve them with a current-schema lookup tool.

5. Latest-row behavior.
   - For "latest measurement", "last row", or "last N rows", use `maxRows` and `fromLast:true` on measurement/chart tools.

6. Multi-station behavior.
   - Prefer one-call solutions using comma-separated `dluName`, comma-separated `dlu_id`, or semantic `filter` when supported.

## Authoritative Tool Names
Prefer these exact names when appropriate:
- Current/latest data: `get_all_devices`, `get_devices_by_name`, `get_devices_around_position`, `get_device`
- Device configuration: `get_device_configuration`
- Historical by id/filter: `get_csv_measurement_data`, `get_json_measurement_data`, `get_excel_measurement_data`, `get_measurement_data_in_chart`
- Historical by name: `get_csv_measurement_data_by_name`, `get_json_measurement_data_by_name`, `get_excel_measurement_data_by_name`, `get_measurement_data_in_chart_by_name`
- Time: `get_server_datetime`
- Forecast: `get_weather_forecast`

Never invent near-miss names such as `get_all_stations`, `get_devices_around_location`, or `getgroupid`.

## Exact Native Output Examples
Valid assistant examples:

- `{"messages": [{"role": "user", "content": "Get the latest weather data for station DLU-123. Respond ONLY with a tool_call JSON object."}, {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "get_devices_by_name", "arguments": {"dluName": "DLU-123", "detail": 1, "grpId": -1}}}]}]}`
- `{"messages": [{"role": "user", "content": "Show rainfall measurements for device 1234 between 20240301000000 and 20240303235959 as CSV. Respond ONLY with a tool_call JSON object."}, {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "get_csv_measurement_data", "arguments": {"dlu_id": 1234, "fromDate": "20240301000000", "toDate": "20240303235959", "channels": "[ALL]"}}}]}]}`
- `{"messages": [{"role": "user", "content": "Give me a 12 hour forecast for coordinates 52.52, 13.405. Respond ONLY with a tool_call JSON object."}, {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "get_weather_forecast", "arguments": {"lat": 52.52, "lng": 13.405, "hours": 12}}}]}]}`
- `{"messages": [{"role": "user", "content": "Get the latest measurement for station Bernburg. Respond ONLY with a tool_call JSON object."}, {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "get_csv_measurement_data_by_name", "arguments": {"dluName": "Bernburg", "channels": "[ALL]", "maxRows": 1, "fromLast": true}}}]}]}`
- `{"messages": [{"role": "user", "content": "Show me a chart of temperature in Berlin"}, {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "no_tool", "arguments": {"reason": "coordinates required"}}}]}]}`

Invalid assistant examples:
- `{"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "tool_call: {\"name\":\"get_all_devices\",\"arguments\":{\"grpId\":-1}}"}]}` (Legacy text wrapper is forbidden)
- `{"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "", "tool_calls": [{"name": "get_all_devices", "arguments": {"grpId": -1}}]}]}` (Missing `"function"` key wrapping the name and arguments)
- `{"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "I will call get_devices_by_name"}]}` (Conversational prose is forbidden)

## Dataset Size and Diversity
- Generate the requested number of examples per batch.
- Include English and German user prompts.
- Mix short, noisy, typo-prone, and conversational prompts.
- Avoid duplicate user prompts.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- Every `tool_calls` array parses as JSON and conforms to the function block structure.
- No unknown tool names.
- No invalid keys.
- Required arguments present.
- Types are valid.

## Final Output
Return raw JSONL only.
