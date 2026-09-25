# Changelog - TealKit CLI (`tealkit_cli`)

All notable changes to the TealKit CLI package will be documented in this file.

## 1.1.1

- **Configurable Tool Iteration Limit (`max_tool_iterations: 100`)**:
  - Increased default exploration tool limit from 10 to 100 iterations.
  - Added support for configuring `max_tool_iterations` in `llm.yaml` or via `--max-tool-iterations` (`-t`) CLI argument.
  - Implemented automatic response synthesis: when the tool limit is reached during deep codebase inspection, the engine gracefully prompts the model to summarize its findings and generate its complete architecture and implementation plan.
- **Full Multi-Turn Trajectory Retention**:
  - `AgentFinalResultEvent` and session persistence now retain all intermediate tool calls, parameters, and tool execution outputs across conversational turns.
  - Resuming sessions or typing `continue` preserves full context of previous file reads and directory scans without starting over.
- **Multi-LLM Configuration Array (`llm.yaml`)**:
  - Added support for configuring multiple named LLM model profiles under an `llms:` / `models:` array in `llm.yaml` (e.g. `deepseek`, `mistral`, `openai`, `ollama`).
  - Added dynamic model switching via CLI arguments (`--llm:<name>`, `--llm <name>`) and interactive slash commands (`/llm:<name>`, `/llm <name>`, `/llm`).
  - Configured global root-level fallback parameters (`temperature: 0.1`, `max_tokens: 8192`, `max_tool_iterations: 100`).
- **Session Recording & Persistence (`.json` / `.md`)**:
  - Implemented session persistence in both JSON (`.json`) and Markdown (`.md`) formats.
  - Added `--save-session <path>`, `--load-session <path>`, and interactive slash commands `/save-session`, `/load-session`, `/session`, and `/clear-session`.
- **Token Usage Tracking & Cost Estimation (`/estimated_costs`)**:
  - Integrated provider-aware cost calculation matrix covering DeepSeek, Mistral, OpenAI, Claude, Gemini, and Ollama.
  - Added `/estimated_costs` (aliases: `/costs`, `/tokens`) command.
- **External MCP Server Uninstallation (`/uninstall`)**:
  - Added `/uninstall <name|id>` and `/uninstall all_mcp` with non-blocking subprocess cache cleanup (`uv cache clean` / `npm cache clean --force`).
- **Native Coding Tools**:
  - Integrated 10 pure-Dart coding tools: `fs_find`, `fs_list_dir`, `fs_read_file`, `fs_write_file`, `fs_replace_text`, `fs_create_dir`, `fs_move`, `fs_delete`, `terminal_exec`, `fetch_web`.

## 1.1.0

- Initial release with remote server orchestration, auto-discovery, AgentSkills execution, and autonomous coding agent REPL (`tealkit code`).
