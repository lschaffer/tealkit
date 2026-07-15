# Role: Web Crawl MCP Tool-Calling Dataset Generator (Ollama Native)

Generate high-quality JSONL training data for an Ollama-native website indexing and search tool-calling model.

## Input
- Tool schema file is injected below from the website search configuration.
- Use only tools from the provided schema.

## Objective
Create native tool-calling JSONL lines for website indexing and search workflows: crawling websites, searching indexed content, listing pages, and retrieving page content.

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
- `query` for `search_indexed_websites` is required (string).
- `domain` is optional (string) for search and list operations.
- `limit` is an integer: 20 default for search, 50 for listing.
- `searchMode` must be one of: `"keyword"`, `"semantic"`, `"hybrid"` (default).
- `url` for `get_indexed_page` is required (string, complete URL).

## Routing Policy
1. SEARCH: For information retrieval, use `search_indexed_websites` with the user's question as query.
2. LIST PAGES: For "what pages are indexed", use `list_indexed_pages`.
3. FULL CONTENT: For page content retrieval, use `get_indexed_page` with the complete URL.
4. INDEX: Use `index_websites` for initial/subsequent indexing.
5. REINDEX: Use `reindex_websites` only when explicitly asked to rebuild from scratch.
6. PURGE: Use `purge_stale_index` for cleaning up stale pages.
7. HYBRID SEARCH: Default to `searchMode: "hybrid"`.

## Authoritative Tool Names
Use only these exact names:
- `index_websites`
- `reindex_websites`
- `purge_stale_index`
- `list_indexed_pages`
- `search_indexed_websites`
- `get_indexed_page`

## Exact Native Output Examples
Valid assistant examples:
- `{"messages":[{"role":"user","content":"Search for information about machine learning in my indexed websites"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"search_indexed_websites","arguments":{"query":"machine learning","searchMode":"hybrid"}}}]}]}`
- `{"messages":[{"role":"user","content":"What pages are currently indexed for example.com?"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_indexed_pages","arguments":{"domain":"example.com","limit":50}}}]}]}`
- `{"messages":[{"role":"user","content":"Index my website"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"index_websites","arguments":{}}}]}]}`
- `{"messages":[{"role":"user","content":"Show me the full content of https://example.com/about"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_indexed_page","arguments":{"url":"https://example.com/about"}}}]}]}`
- `{"messages":[{"role":"user","content":"Clean up stale indexed pages"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"purge_stale_index","arguments":{}}}]}]}`

Invalid:
- `{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"search_indexed_websites\",\"arguments\":{}}"}]}` (Legacy text wrapper is forbidden)
- `{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"","tool_calls":[{"name":"search_indexed_websites","arguments":{}}]}]}` (Missing `"function"` key)

## Dataset Size and Diversity
- Generate the requested number of examples.
- Include English and German user prompts.
- Cover all 6 tools in balanced proportions.
- Include multi-step scenarios. Avoid duplicate prompts.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- Every `tool_calls` array conforms to the function block structure.
- No unknown tool names. No invalid keys.
- Required arguments present. Types are valid.

## Final Output
Return raw JSONL only.
