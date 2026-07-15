# Server Updates

## v1.0.52

### Changes
- AI SDK Upgrade: Migrated to direct native provider SDKs (`openai_dart`, `anthropic_sdk_dart`, `ollama_dart`, `googleai_dart`), fully removing `langchain` wrapper packages.
- Stable Tool Call IDs: Replaced shifting timestamps with stable, deterministic tool call IDs based on function name and parameter hashes for Gemini and Ollama.
- Ollama Loop Prevention: Injected loop prevention system instructions to system prompts when running Ollama model generation turns.

## v1.0.51

### Changes
- Index freshness fix: website/document background indexing now persists `last_indexed_at` on successful completion.
- Stale result isolation: website/document query APIs now scope results to currently configured website seeds/domains and document root paths.
- Scheduled indexing support: server scheduler now triggers website/document indexing from their configured cron schedules.
- URL output hardening: result normalization now also strips trailing markdown emphasis artifacts like `)*` / `)**` after links.

## v1.0.50

### Changes
- Server-side markdown link normalization: final task results now rewrite bold-wrapped links from `**[Title](https://...)**` to plain `[Title](https://...)` before persistence and notifications.
- This hardens link output for email/mobile clients so trailing markdown delimiters are not interpreted as part of the URL.

## v1.0.49

### Changes
- MCP server-mode fix: `gh_mcp_*` internal MCP entries are now connected correctly in the server tool registry, so configured GitHub MCP tools are available during server runs.
- Link output fix: web result formatting now explicitly avoids bold-wrapped markdown links like `**[Title](url)**` and uses plain `[Title](url)` so email/mobile clients do not include trailing `)` in tappable URLs.
