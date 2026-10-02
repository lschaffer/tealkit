# Changelog - TealKit CLI (`tealkit_cli`)

All notable changes to the TealKit CLI package will be documented in this file.

## 1.1.3

- **Fixed MCP Uninstallation Workflow (`/uninstall <name|all_mcp>`)**:
  - Uninstalls local MCP packages directly from the filesystem (`npm uninstall -g <pkg>` for Node.js, `uv tool uninstall <pkg>` for Python, or cleaning local `.venv`).
  - Switched behavior to update `mcp.yaml` by setting `enabled: false` (persisting the server entry rather than destroying it).
  - For remote servers (`https://...`), files are left untouched and only disabled in `mcp.yaml`.
  - Disconnects and unregisters the server from the live multi-client MCP manager immediately.
  - Eliminated disruptive package manager cache purges (`npm cache clean --force` / `uv cache clean` removed).
- **Dynamic MCP Function Inspection & Filtering**:
  - `/mcp_inspect [server_name]`: Interactively inspects all available tools, transports, active whitelist states, and JSON schemas for external MCP servers and built-in tools.
  - `/mcp_enable_fnc <server_name> <fnc1,fnc2,...>`: Temporarily restricts/whitelists the visible functions of a server in-memory for the current session (valid until `/bye`, process exit, or reset).
  - `/mcp_reset_fnc [server_name]`: Clears all function restrictions and restores tool visibility across one or all MCP servers.
- **Built-in TealKit MCP Tools**:
  - `web_search`: Configured via `web_search.yaml` with multi-provider fallback (`serpapi`, `serper`, and free `duckduckgo` Instant Answer).
  - `create_mermaid_png`: Converts Mermaid diagrams (`flowchart`, `sequenceDiagram`, `classDiagram`, `erDiagram`, etc.) into PNG files via the Kroki API.
  - `toolbox`: General calculation and metadata utility tools (`get_current_time`, `get_timezone_info`, `calculate`, `sum_numbers`, `geocode_city`).
  - `ssh`: Configured via `ssh.yaml` (`host`, `port`, `username`, `password`, `private_key`) offering remote execution and SFTP file operations (`ssh_list_directory`, `ssh_read_file`, `ssh_upload_file`, `ssh_download_file`, `ssh_make_directory`, `ssh_remove_directory`, `ssh_execute_command`).

## 1.1.2

- **Global Configuration Initialization & `--reinit` Parameter**:
  - Added automatic detection on first startup if the user's global settings directory (`~/.tealkit/` on Linux/macOS or `%USERPROFILE%\.tealkit` on Windows) exists.
  - Interactively prompts to create the global configuration directory if not found (`Create global directory for settings at ...? [y/N]`).
  - Added `--reinit` command-line flag to force reinitializing and re-copying settings into the global `.tealkit` directory.
  - Automatically copies `.env`, `llm.yaml`, `mcp.yaml`, all other `*.yaml` files, and recursively syncs the `skills/` directory from the installation/working directory into `~/.tealkit/`.
- **Enhanced .NET Skills**:
  - Added `dotnet-engineer-skill.md` for end-to-end WinForms modernization, service layer testing, and project upgrades.

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
