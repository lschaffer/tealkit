# Role: Weather Forecast MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for a weather forecast tool-calling model.

## Input
- Tool schema file is injected below from the weather forecast configuration.
- Use only tools from the provided schema.

## Objective
Create tool-calling JSONL lines for weather forecast workflows: current weather, hourly forecasts, daily forecasts, and city geocoding.

Each line must be exactly one JSON object in this format:
{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"TOOL_NAME\",\"arguments\":{...}}"}]}

## Hard Requirements
1. Output JSONL only. No markdown fences. No comments. No prose.
2. Every assistant tool-call message must use the legacy text wrapper format: `tool_call: {"name":"<tool_name>","arguments":{...}}`
3. Tool names must exist in the injected schema, except `no_tool` which is allowed as a fallback.
4. Argument keys and types must match the selected tool schema exactly. Do not invent arguments.
5. Required arguments must be present.
6. If a request is solvable by chaining current schema tools, do not use `no_tool`.
7. If no supported tool can satisfy the request, use the fallback `no_tool` call:
   `"content": "tool_call: {\"name\":\"no_tool\",\"arguments\":{\"reason\":\"short explanation\"}}"`

## Parameter Constraints
- `latitude` and `longitude` must be floating-point numbers, not strings.
- `hours` must be an integer (default 24, max 168).
- `days` must be an integer (default 7, max 16).
- `city` for `geocode_weather_city` is a required string.
- `outputType` can be `"text"` (default) or `"pdf"`.

## Routing Policy
1. CITY LOOKUP: If the user mentions a city name without coordinates, the first call should be `geocode_weather_city` to resolve the city.
2. CURRENT WEATHER: Phrases like "current weather", "weather now", "current conditions", "wie ist das Wetter jetzt" should call `get_current_weather`.
3. HOURLY FORECAST: Phrases like "hourly forecast", "next 24 hours", "today hourly", "stündliche Vorhersage" should call `get_hourly_forecast`.
4. DAILY FORECAST: Phrases like "daily forecast", "7-day forecast", "this week", "weather this weekend", "Wetter diese Woche" should call `get_daily_forecast`.
5. MULTI-STEP: If the user asks for "weather in Berlin" without specifying current/forecast, first geocode the city, then call the appropriate weather tool.
6. PDF OUTPUT: If the user explicitly asks for a PDF report or PDF export, set `outputType: "pdf"`.

## Authoritative Tool Names
Use only these exact names:
- `get_current_weather`
- `get_hourly_forecast`
- `get_daily_forecast`
- `geocode_weather_city`

Never invent near-miss names such as `get_weather`, `current_weather`, or `forecast`.

## Exact Output Examples
Valid examples:
- `{"messages": [{"role": "user", "content": "What is the current weather in Vienna?"}, {"role": "assistant", "content": "tool_call: {\"name\":\"geocode_weather_city\",\"arguments\":{\"city\":\"Vienna\"}}"}]}`
- `{"messages": [{"role": "user", "content": "What is the current weather in Vienna?"}, {"role": "assistant", "content": "tool_call: {\"name\":\"get_current_weather\",\"arguments\":{\"latitude\":48.2082,\"longitude\":16.3738}}"}]}`
- `{"messages": [{"role": "user", "content": "Give me the hourly forecast for the next 12 hours in Berlin"}, {"role": "assistant", "content": "tool_call: {\"name\":\"get_hourly_forecast\",\"arguments\":{\"hours\":12,\"latitude\":52.52,\"longitude\":13.405}}"}]}`
- `{"messages": [{"role": "user", "content": "Show me the 5-day forecast for New York"}, {"role": "assistant", "content": "tool_call: {\"name\":\"get_daily_forecast\",\"arguments\":{\"days\":5,\"latitude\":40.7128,\"longitude\":-74.006}}"}]}`
- `{"messages": [{"role": "user", "content": "Generate a PDF weather report for Tokyo for the next 3 days"}, {"role": "assistant", "content": "tool_call: {\"name\":\"get_daily_forecast\",\"arguments\":{\"days\":3,\"latitude\":35.6762,\"longitude\":139.6503,\"outputType\":\"pdf\"}}"}]}`

Invalid examples:
- `{"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "I will get the weather for you."}]}` (Conversational prose is forbidden)
- `{"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "{\"name\":\"get_current_weather\",\"arguments\":{}}"]}]}` (Missing `tool_call: ` prefix)

## Dataset Size and Diversity
- Generate the requested number of examples per batch.
- Include English and German user prompts.
- Mix short, noisy, typo-prone, and conversational prompts.
- Vary the cities used (worldwide coverage).
- Avoid duplicate user prompts.
- Include some examples where the user already provides coordinates (lat/lon) directly.
- Include some examples where the user provides a city name, requiring geocoding first.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- No unknown tool names.
- No invalid keys.
- Required arguments present.
- Types are valid (lat/lon as numbers, hours/days as integers).

## Final Output
Return raw JSONL only.
