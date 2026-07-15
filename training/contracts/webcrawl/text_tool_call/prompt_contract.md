# Role: Web Crawl MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for a website indexing and search tool-calling model.

## Input
- Tool schema file is injected below from the website search configuration.
- Use only tools from the provided schema.

## Objective
Create tool-calling JSONL lines for website indexing and search workflows: crawling websites, searching indexed content, listing pages, and retrieving page content.

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
- `query` for `search_indexed_websites` is required (string).
- `domain` is optional for `search_indexed_websites` and `list_indexed_pages` (string).
- `limit` is an integer with defaults: 20 for search, 50 for listing.
- `searchMode` must be one of: `"keyword"`, `"semantic"`, `"hybrid"` (default).
- `url` for `get_indexed_page` is required (string, complete URL).

## Routing Policy
1. SEARCH: For information retrieval or "find information about X", use `search_indexed_websites` with the user's question as the query.
2. LIST PAGES: For "what pages are indexed" or "list indexed pages", use `list_indexed_pages`. Optionally filter by domain.
3. FULL CONTENT: For "show me the full content of URL X" or "details about this page", use `get_indexed_page` with the complete URL.
4. INDEX: For "index my website", "crawl my site", "start indexing", use `index_websites`.
5. REINDEX: For "reindex", "rebuild the index", "start fresh", use `reindex_websites`.
6. PURGE: For "clean up stale pages", "remove old indexed content", use `purge_stale_index`.
7. HYBRID SEARCH: By default, use `searchMode: "hybrid"` for the best mix of keyword and semantic search.
8. DOMAIN NARROWING: If the user asks about a specific domain, add the `domain` filter parameter.
9. GERMAN PROMPTS: "Suche nach", "finde Informationen über", "zeige indizierte Seiten", "crawle Website" should map to the appropriate tools.

## Authoritative Tool Names
Use only these exact names:
- `index_websites`
- `reindex_websites`
- `purge_stale_index`
- `list_indexed_pages`
- `search_indexed_websites`
- `get_indexed_page`

Never invent near-miss names such as `search_websites`, `crawl_websites`, or `get_website_content`.

## Exact Output Examples
Valid examples:
- `{"messages": [{"role": "user", "content": "Search for information about machine learning in my indexed websites"}, {"role": "assistant", "content": "tool_call: {\"name\":\"search_indexed_websites\",\"arguments\":{\"query\":\"machine learning\",\"searchMode\":\"hybrid\"}}"}]}`
- `{"messages": [{"role": "user", "content": "What pages are currently indexed for example.com?"}, {"role": "assistant", "content": "tool_call: {\"name\":\"list_indexed_pages\",\"arguments\":{\"domain\":\"example.com\",\"limit\":50}}"}]}`
- `{"messages": [{"role": "user", "content": "Index my website"}, {"role": "assistant", "content": "tool_call: {\"name\":\"index_websites\",\"arguments\":{}}"}]}`
- `{"messages": [{"role": "user", "content": "Rebuild the entire index from scratch"}, {"role": "assistant", "content": "tool_call: {\"name\":\"reindex_websites\",\"arguments\":{}}"}]}`
- `{"messages": [{"role": "user", "content": "Show me the full content of https://example.com/about"}, {"role": "assistant", "content": "tool_call: {\"name\":\"get_indexed_page\",\"arguments\":{\"url\":\"https://example.com/about\"}}"}]}`
- `{"messages": [{"role": "user", "content": "Clean up stale indexed pages"}, {"role": "assistant", "content": "tool_call: {\"name\":\"purge_stale_index\",\"arguments\":{}}"}]}`
- `{"messages": [{"role": "user", "content": "Suche nach Deep Learning in meiner Dokumentation"}, {"role": "assistant", "content": "tool_call: {\"name\":\"search_indexed_websites\",\"arguments\":{\"query\":\"Deep Learning\",\"searchMode\":\"hybrid\"}}"}]}`

## Dataset Size and Diversity
- Generate the requested number of examples per batch.
- Include English and German user prompts.
- Mix short, noisy, typo-prone, and conversational prompts.
- Cover all 6 tools in roughly balanced proportions.
- Include multi-step scenarios (e.g., search → found a page → get full content).
- Avoid duplicate user prompts.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- No unknown tool names. No invalid keys.
- Required arguments present. Types are valid.

## Final Output
Return raw JSONL only.
