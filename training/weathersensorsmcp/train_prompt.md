# Role: Weather Sensors MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for a small model that maps user requests to tool calls for the CURRENT `weather_sensors_tools.jsonl` schema.

## Source of Truth
- The authoritative schema is injected below from `scripts_training/weathersensorsmcp/mcp_data/weather_sensors_tools.jsonl`.
- Keep every example synchronized with that current schema.
- Do not invent helper tools that are not present in the schema.

## Output Contract
Return JSONL lines only, one JSON object per line.

Canonical tool-call rows:

{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"TOOL_NAME\",\"arguments\":{...}}"}]}

The canonical assistant tool-call shape is always:

- `tool_call: {"name":"<tool_name>","arguments":{...}}`

Forbidden output shapes:

- `{"tool_call":"some_tool?..."}`
- `{"command":"get_weather_data",...}`
- `{"action":"fetch_measurement_data",...}`
- `{"tool":"weather",...}`
- `{"function":"...","parameters":{...}}`
- `<tool_call>...</tool_call>`
- any explanatory prose around the tool call

## Hard Requirements
1. Output JSONL only. No markdown fences. No prose.
2. Every tool-call assistant message must begin with `tool_call: `.
3. Tool call JSON must contain `name` and `arguments`.
4. Tool names must exist in the injected schema, except `no_tool` which is allowed as a fallback.
5. Argument keys and types must match the selected tool schema.
6. Required arguments must be present.
7. Never use `parameters` instead of `arguments`.
8. Never append explanation text after the tool call.
9. If a request is solvable by chaining current schema tools, do not use `no_tool`.
10. Do not generate plain-text follow-up answer rows in this dataset. This generation stage is tool-call-only.

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

5. `grpId` is still part of the current schema.
   - Use `grpId:-1` in examples when the selected tool requires or expects it.
   - Do not invent `getgroupid`; it is not part of this schema.

6. `detail=1` is the default current-data lookup level.
   - Use `detail:1` by default for lookup/current data examples unless a prompt clearly needs another level.

7. Channels are strings.
   - For all-channel measurement/chart requests, use `"ALL"` or `"[ALL]"`.
   - Never use `null` for `channels`.

8. Latest-row behavior.
   - For "latest measurement", "last row", or "last N rows", use `maxRows` and `fromLast:true` on measurement/chart tools.

9. Multi-station behavior.
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

## Required Coverage
Include broad positive coverage for:
- current data by station name
- current data around a location/position
- current data with `fields` and `filter`
- device info/config requests
- historical CSV/JSON/Excel exports
- by-name measurement requests
- latest measurement requests with `maxRows` and `fromLast:true`
- forecast requests with coordinate pre-resolution when needed
- multi-station requests using one call where supported
- file outputs where supported

## Required Contrastive Examples
Include explicit contrastive teaching for:
1. "current weather in X" -> actual/current-data lookup tool, not measurement export
2. "forecast for station X" without coordinates -> lookup first, then forecast
3. "last 6 hours for station Bernburg" -> direct `*_by_name` measurement tool, not lookup first
4. multi-station requests -> one call with comma-separated IDs or names where supported
5. canonical `tool_call: {"name":"...","arguments":{...}}` only
6. no prose around tool calls
7. no `no_tool` when the request is solvable via lookup + time + another supported tool
8. invalid wrappers contrasted against the canonical form
9. direct probe-like examples for these exact requests:
   - `Get the latest weather data for station DLU-123. Respond ONLY with a tool_call JSON object.`
   - `Show rainfall measurements for device 1234 between 20240301000000 and 20240303235959 as CSV. Respond ONLY with a tool_call JSON object.`
   - `Give me a 12 hour forecast for coordinates 52.52, 13.405. Respond ONLY with a tool_call JSON object.`
   - `Get the latest measurement for station Bernburg. Respond ONLY with a tool_call JSON object.`
10. do not emit any direct-answer follow-up examples in this generation stage; every assistant row must still be a tool_call row

## Exact Output Examples
Valid assistant examples:

- `tool_call: {"name":"get_devices_by_name","arguments":{"dluName":"DLU-123","detail":1,"grpId":-1}}`
- `tool_call: {"name":"get_csv_measurement_data","arguments":{"dlu_id":1234,"fromDate":"20240301000000","toDate":"20240303235959","channels":"rainfall"}}`
- `tool_call: {"name":"get_weather_forecast","arguments":{"lat":52.52,"lng":13.405,"hours":12}}`
- `tool_call: {"name":"get_csv_measurement_data_by_name","arguments":{"dluName":"Bernburg","channels":"[ALL]","maxRows":1,"fromLast":true}}`
- `tool_call: {"name":"no_tool","arguments":{"reason":"not covered by available tools"}}`

Invalid assistant examples:

- `{"tool_call":"get_all_devices?grpId=-1&detail=1"}`
- `{"action":"fetch_measurement_data","parameters":{"device_id":1234}}`
- `tool_call: {"function":"get_all_devices","parameters":{"grpId":-1}}`
- `tool_call: {"name":"get_all_stations","arguments":{}}`
- `tool_call: {"name":"getgroupid","arguments":{}}`
- `tool_call: {"name":"get_all_devices","arguments":{"grpId":-1}} extra explanation here`

## Dataset Size
- Minimum: 360 examples
- Target: 420-520 examples

## Composition Targets
- 75-85% positive tool calls
- 15-25% `no_tool`

## Language and Style Diversity
- Include English and German user prompts.
- Mix short, noisy, typo-prone, and conversational prompts.
- Include realistic operations language for monitoring workflows.
- Avoid duplicate prompts.

## Quality Gate Before Final Output
- Every line parses as JSON.
- Every `tool_call` payload parses as JSON.
- No unknown tool names.
- No invalid keys.
- Required arguments present.
- Types are valid.
- Every assistant message starts with `tool_call: `.

## Final Output
Return raw JSONL only.