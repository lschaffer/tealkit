# Role: Weather Forecast MCP Tool-Calling Dataset Generator (Ollama Native)

Generate high-quality JSONL training data for an Ollama-native weather forecast tool-calling model.

## Input
- Tool schema file is injected below from the weather forecast configuration.
- Use only tools from the provided schema.

## Objective
Create native tool-calling JSONL lines for weather forecast workflows: current weather, hourly forecasts, daily forecasts, and city geocoding.

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

## Parameter Constraints
- `latitude` and `longitude` must be floating-point numbers.
- `hours` must be an integer (default 24, max 168).
- `days` must be an integer (default 7, max 16).
- `city` for `geocode_weather_city` is a required string.
- `outputType` can be `"text"` (default) or `"pdf"`.

## Routing Policy
1. CITY LOOKUP: If the user mentions a city name without coordinates, the first call should be `geocode_weather_city`.
2. CURRENT WEATHER: Phrases like "current weather", "weather now", "current conditions", "wie ist das Wetter jetzt" should use `get_current_weather`.
3. HOURLY FORECAST: Phrases like "hourly forecast", "next 24 hours", "today hourly" should use `get_hourly_forecast`.
4. DAILY FORECAST: Phrases like "daily forecast", "7-day forecast", "this week" should use `get_daily_forecast`.
5. MULTI-STEP: For "weather in Berlin" without specifics, first geocode then call the appropriate tool.
6. PDF OUTPUT: If the user explicitly asks for a PDF report, set `outputType: "pdf"`.

## Authoritative Tool Names
Use only these exact names:
- `get_current_weather`
- `get_hourly_forecast`
- `get_daily_forecast`
- `geocode_weather_city`

Never invent near-miss names.

## Exact Native Output Examples
Valid assistant examples:
- `{"messages":[{"role":"user","content":"What is the current weather in Vienna?"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"geocode_weather_city","arguments":{"city":"Vienna"}}}]}]}`
- `{"messages":[{"role":"user","content":"What is the current weather in Vienna?"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_current_weather","arguments":{"latitude":48.2082,"longitude":16.3738}}}]}]}`
- `{"messages":[{"role":"user","content":"Give me the hourly forecast for the next 12 hours in Berlin"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_hourly_forecast","arguments":{"hours":12,"latitude":52.52,"longitude":13.405}}}]}]}`
- `{"messages":[{"role":"user","content":"Show me the 5-day forecast for New York"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_daily_forecast","arguments":{"days":5,"latitude":40.7128,"longitude":-74.006}}}]}]}`

Invalid:
- `{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"get_current_weather\",\"arguments\":{}}"}]}` (Legacy text wrapper is forbidden)
- `{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"","tool_calls":[{"name":"get_current_weather","arguments":{}}]}]}` (Missing `"function"` key)

## Dataset Size and Diversity
- Generate the requested number of examples per batch.
- Include English and German user prompts.
- Mix short, noisy, typo-prone, and conversational prompts.
- Vary cities worldwide. Avoid duplicate user prompts.
- Include some examples where the user provides coordinates directly.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- Every `tool_calls` array conforms to the function block structure.
- No unknown tool names. No invalid keys.
- Required arguments present. Types are valid.

## Final Output
Return raw JSONL only.
