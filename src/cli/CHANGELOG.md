# Changelog - TealKit CLI (`tealkit_cli`)

All notable changes to the TealKit CLI package will be documented in this file.

## 1.4.6

- **Native `rag_search` Tool & Dedicated `rag` Mode in RPC/CLI**:
  - Added `CodingMode.rag` support to `tealkit rpc` / `tealkit code` and added `_RagSearchTool` (`rag_search`) to query `rag_index.db` cleanly without opening binary `.docx`/`.pdf` files via `fs_read_file`.
  - Restricted `CodingMode.rag` tools to RAG & non-filesystem utilities and truncated verbose `AgentLogEvent` prompt dumps before emitting `log` events.
- **Tool Permission & Model Sync Fixes**:
  - Synchronized `ToolPermissionSettings.save()` with `config.yaml` and unwrapped `mcp_call_tool` inner tool/risk when handling `Always Allow` in `TealKitRpcEngine`.
  - Fixed `model_changed` RPC event to report the active profile name so IDE dropdowns keep non-default selections active.
- **Clean Distribution Package (`tealkit_cli_setup.zip`)**:
  - Updated starter configs (`config.yaml`, `mcp.yaml`, `server.yaml`, `ssh.yaml`, `web_search.yaml`) to start clean/empty (while preserving starter profiles in `llm.yaml`) and packaged only the 2 starter skills (`coding-agent-skill.md`, `dotnet-engineer-skill.md`) updated with Git commit instructions.

## 1.4.5

- **Clean Default `config.yaml` & RAG Templates for Distribution**:
  - Removed all predefined organization-specific folder/web paths from default `config.yaml` templates and `RagConfig` defaults (`folders: []`, `web: []`, `database_path: "rag_index.db"`).
  - Added `agent.max_tool_iterations` (default `100`) and `permissions` section to `config.yaml` and `CliConfig`.
- **RPC Engine Live Configuration & Workflow Management**:
  - Added `reload_config` and `reload_mcp` RPC actions for live configuration and MCP tool reloading without restarting the session.
  - Added `get_workflow_status`, `get_workflow_logs`, and `cancel_workflow` RPC actions backed by `ServerApiClient` (`getTaskRunStatus`, `getTaskExecutionLogs`, `getTaskOutput`, `cancelTask`).

## 1.4.4

- **Dynamic Context Compression Scaling**:
  - Dynamically calculates `effectiveCompressionThreshold`, scaling up to 16,000+ tokens for full cloud models (e.g. Gemma 31B, 262k ctx) instead of hardcoding 4,000 tokens, eliminating single-turn compression loops.
- **Direct Tool Schema Exposure for IDE / RPC Mode**:
  - Automatically disables progressive discovery meta-tools (`mcp_list_tools`, `mcp_call_tool`) in RPC mode so AI models directly receive all registered tool schemas for faster and more accurate tool call generation.
- **RPC Observability & Event Streaming**:
  - Added real-time broadcasting for `AgentLogEvent` over stdio RPC (`type: 'log'`).
  - Standardized permission request event payload to include both `requestId`/`id` and `tool`/`toolName` for seamless IDE human-in-the-loop approvals.
- **Template Compatibility & Safety (dart_mcp_core: ^1.5.10)**:
  - Sanitized OpenAI-compatible assistant tool calls to serialize `content: ''` (empty string) instead of `null`, preventing Python/vLLM Jinja template `BadRequestException: can only concatenate str (not "NoneType") to str`.
  - Added threshold safeguards in `ContextCompressor` requiring minimum turn count and split depth.

## 1.4.3

- **Headless JSON-RPC Engine (`TealKitRpcEngine`) for IDE Integrations**:
  - Added line-delimited JSON-RPC protocol over `stdin`/`stdout` powering IDE extensions (VS Code, Antigravity, Cursor).
  - New top-level CLI command `tealkit rpc [--workspace <path>] [--mode <code|architect|ask|rag>] [--llm <profile>] [--tools <path>]`.
  - Added headless flag to coding command: `tealkit code --rpc [--workspace <path>]`.
  - Stdio streaming events: `ready`, `status`, `models`, `skills`, `mcp_tools`, `start`, `chunk`, `tool_result`, `diff`, `plan`, `subagent_start`, `subagent_done`, `usage`, `error`, `done`.
  - Interactive actions supported via JSON: `ping`, `get_status`, `list_models`, `set_model`, `set_mode`, `list_skills`, `list_mcp_tools`, `prompt`, `cancel`, `clear_session`, `permission_response`, `exit`.
  - Non-JSON stdout diagnostics redirected to stderr or silenced via `{bool silent = true}` in MCP runner.
- **Automated Deployment Pipeline (`cli/deploy.ps1`)**:
  - Unified deployment script delegating to `setup.ps1` for compilation, staging, packaging `tealkit_cli_setup.zip`, and automatic upload to `https://tealkit.dev/download/tealkit_cli_setup.zip`.

## 1.4.2

- **Pure Dart Fetch MCP Server Integration (FetchMcpServer)**:
  - Registered etch tool for direct web page content extraction into Markdown/text with character limits and pagination.
  - Skips non-document binary file downloads (.msi, .exe, etc.).
- **Sub-Agent Delegation Whitelist Alignment**:
  - Aligned sub-agent tool whitelists across mobile and desktop environments.

## 1.4.1

- **Predefined Specialized Sub-Agents Catalog (`SubAgentDefinition.predefined`)**:
  - Built-in availability of 5 specialized sub-agents adapted from ThiesCoder (`unit_tester`, `git_auditor`, `web_researcher`, `code_scout`, `c_analyzer`).
  - Seamless invocation via `delegate_task` in `tealkit code` and `tealkit chat` without requiring manual YAML configuration.
  - Automatically maps `model: "default"` to the currently active LLM profile name.
  - Added smart tool alias matching (`web_search` and `fetch_web`).
- **Windows Native DLL Helper (`windows_dll_helper.dart`)**:
  - Implemented automatic DLL search path configuration using Win32 `SetDllDirectoryW` via `dart:ffi`.
  - Ensures sibling native runtime libraries (`llamadart.dll`, `llama.dll`, `ggml-*.dll`, `pdfium.dll`, `dxcompiler.dll`, `vcomp140.dll`) load reliably across arbitrary working directories on Windows.
- **Architect `/plan` Mode Safety Guard**:
  - Stricter enforcement preventing destructive source file edits and terminal commands while in `/plan` mode.

## 1.4.0

- **Progressive MCP Tool Discovery (`dart_mcp_core: ^1.2.0`)**:
  - Dynamically registers `McpListToolsTool` (`mcp_list_tools`) and `McpCallToolTool` (`mcp_call_tool`) to discover, filter, and invoke tools on connected MCP servers on-demand.
  - Slashes LLM system prompt context consumption from 5,000–15,000+ tokens down to ~250 tokens when connecting multiple large MCP servers (Git, FileSystem, Database, Slack, Weather, etc.).
  - Configurable via `progressive_tools: 'auto' | 'on' | 'off'` in `config.yaml` or CLI arguments (`--progressive <mode>`). In `auto` mode, activates automatically when total tools exceed 25 or when running compact local SLMs / embedded models.
  - Added interactive `/progressive [auto|on|off]` command in both `tealkit chat` and `tealkit code` REPLs.
- **Terminal Multiline Input & Configurable Submit Keys (`submit_key`)**:
  - High-performance raw terminal reader in `cli_prompt_reader.dart` supporting multiple submission key configurations:
    - `ctrl-enter` (default): Enter moves to a new line with dim `... ` continuation prompt; `Ctrl+Enter`, `Ctrl+D` (EOT), or `Ctrl+Z` (SUB) submits.
    - `double-enter`: Enter inserts newlines; pressing Enter twice consecutively on an empty line submits.
    - `enter`: Classic single-line Enter submission with `\` continuation and `"""` triple-quote blocks.
  - Added interactive `/multiline [on|off]` command and `/paste` clipboard detection.
  - Seamless in-terminal `Ctrl+V` clipboard paste support for multiline code blocks, Markdown text, and instant screenshot image attachment.
- **Local RAG Subsystem & Hybrid Retrieval Engine**:
  - Inbuilt local document and web knowledge base powered by SQLite FTS5 (BM25 keyword search) and embedded local GGUF vectors (`nomic-embed-text-v1.5.Q4_K_M.gguf`).
  - Implements **Reciprocal Rank Fusion (RRF)** to dynamically fuse keyword and vector rankings for high precision on technical codes, acronyms, and semantic concepts.
  - Multi-threaded embedding with automatic GPU offloading (`gpuLayers: 99`) and safe fallback to multi-core CPU.
  - Supports documents (`.pdf`, `.docx`, `.txt`, `.md`, `.csv`, `.json`).
- **Inbuilt Pure Dart Web Crawler (`max_pages`)**:
  - Replaces external web fetch MCP servers with an autonomous, pure-Dart web crawler.
  - Breadth-first crawl traversal respecting domain and subpath boundaries (e.g., seeding `/docs` restricts crawling to `/docs`).
  - Configurable `max_pages` parameter per website (default: 50).
  - Skips non-HTML resources, template placeholders, utility/auth noise paths, and extracts clean article text and page titles.
- **Clickable File Links & Precise Line Number Tracking**:
  - Chunks now calculate and store original file starting and ending line numbers (`line_start`, `line_end`).
  - Search results display clickable `file:///` URIs and terminal-friendly `path:line` format for instant **Ctrl+Click** navigation in VS Code and Windows Terminal.
  - Enhanced LLM context injection in `buildPromptContext`: passes precise file links, chunk/line references, and explicit citation instructions to the assistant.
- **CLI & Interactive Commands**:
  - `tealkit rag reindex [-p|--max-pages <N>]`: Rebuilds or incrementally updates local RAG index.
  - `tealkit rag status`: Inspects indexed documents, total chunks, vector embeddings, and storage size.
  - `tealkit rag search <query>`: Executes instant hybrid search across indexed files and web pages.
  - Interactive chat & coding agent commands: `/rag [on|off|status]`, `/rag search <query>`, and `/reindex [max_pages]`.
  - Added `/rag` (Knowledge / RAG) submode in both CLI coding agent and TealKit Desktop Assistant.
- **Automatic Multimodal Image Downscaling & Memory Optimization**:
  - Integrated `ImageOptimizer` to automatically downscale attached images (e.g., high-resolution camera captures) to 768px bounds using native hardware decoders, protecting local SLM context memory and GPU VRAM.
- **Core Dependency Synchronization**:
  - Upgraded to `dart_mcp_core: ^1.2.0` with structured agent planning (`WriteTodosTool`, `PlanState`), context auto-compression (`ContextCompressor`), and agent lifecycle interceptors (`AgentHook`).

## 1.3.0

- **TealKit MCP Server (`tealkit mcp-serve` / `tealkit mcp serve`)**:
  - Exposes TealKit as a full Model Context Protocol (MCP) JSON-RPC 2.0 stdio server.
  - Allows external frontier AI clients (Claude Desktop, Cursor, Roo Code / Cline, VS Code Copilot) to directly invoke TealKit tools, local DuckDB RAG vector queries, offline SLM models, and multi-step AgentSkill workflows.
  - Dynamically inspects registered workflows and turns each into a sanitized MCP tool (`wf_<name>`) with typed JSON Schema specifications.
  - Provides core MCP primitives:
    - **Tools**: `tealkit_rag_query`, `tealkit_run_workflow`, `tealkit_run_skill`, `tealkit_slm_process`, and dynamic workflow tools.
    - **Resources**: `tealkit://workflows`, `tealkit://models`, `tealkit://skills`, `tealkit://rag/collections`.
    - **Prompts**: `tealkit_code_review`, `tealkit_rag_search`.
- **Dual Transport Layers (Local Stdio & Remote HTTP/SSE)**:
  - Supports standard local desktop stdio communication (`tealkit mcp-serve`).
  - Supports remote HTTP / Server-Sent Events (SSE) daemon mode (`tealkit mcp serve --sse --port 8081`) with CORS, session routing (`GET /sse`, `POST /message?sessionId=...`), Bearer token authentication (`--api-key`), and TLS/HTTPS (`--cert`, `--key`) for 24/7 cloud, home lab, and team deployments.
- **Client Configuration Installer (`tealkit mcp install-claude` & `tealkit mcp config`)**:
  - Automatic cross-platform discovery and safe merging into `claude_desktop_config.json` on Windows, macOS, and Linux without disturbing other configured servers.
  - Generates ready-to-copy configuration snippets for Cursor and Roo Code.
- **AI Agent Package Upgrades**:
  - Upgraded `openai_dart` from `^10.0.0` to `^11.0.1`.
- **Public MCP Registry Support**:
  - Added root `smithery.yaml` for 1-click installation via Smithery.ai and listing on Glama.ai / awesome-mcp-servers.

## 1.2.1

- **Startup Missing MCP Server Auto-Installation & Auto-Repair**:
  - Automatically detects missing local MCP servers at CLI startup by inspecting tool availability (e.g. `uv tool list`).
  - Automatically runs package installation (`uv tool install --force` with Python compatibility flags or `npm install -g`) before connecting, matching the behavior of the TealKit App / Server.
  - Implements automatic retry and repair on connection failure: if an active local MCP server fails to connect on startup, the CLI automatically runs re-installation and retries connection before reporting an error.
  - Added compatibility normalization for `mcp-server-fetch` to inject `--with "pydantic<2.10" --with "mcp<1.3.0"` on Python 3.13 / uvx, preventing `ImportError: cannot import name 'McpError'` and Pydantic crashes.
- **On-Demand MCP Server Installation (`/install`)**:
  - Added interactive `/install <name|all_mcp>` command to `code` and `chat` commands.
  - Installs the underlying package, enables it in `mcp.yaml`, connects the MCP client, and immediately registers available tools with `MultiMCPManager` for interactive use without restarting the session.

## 1.2.0

- **Compact Tool Call Mode (`/compact on | off`)**:
  - Added new `/compact [on|off]` command (enabled by default) and `--compact` CLI option.
  - When enabled, file-reading operations (`fs_read_file`, `ssh_read_file`, `read_file`) suppress verbose file contents in the terminal output, displaying only the target file path and line counts (similar to Claude Code and Roo Code).
  - Preserves error reporting when file reads fail, while allowing users to disable compact mode with `/compact off` to view the full file content stream.
- **Session Transcript Replay (`/load-session`)**:
  - Restoring a session via `/load-session <path>` or startup `--load-session <path>` now prints the conversation history as originally entered (user prompts, tool cards respecting compact mode, and assistant responses).
  - Replays and formats all turns locally without re-transmitting requests to the LLM or consuming tokens.
- **Embedded GGUF Model Support (`llamadart`) & Auto-Download**:
  - Integrated local offline LLM execution using `llamadart` GGUF engine.
  - Added support for `provider: "embedded"` in `llm.yaml` with custom parameters (`repo`, `model`, `gpu_layers`, `context_size`).
  - Added automatic download with interactive progress reporting from HuggingFace to `~/.tealkit/models/` when model files are not found locally.
  - Dynamic switching to embedded models via `/llm <profile_name>`.
- **Prompt Attachments & Clipboard Integration**:
  - `/attach <filepath>` or `/attach-file <filepath>`: Attaches local documents (PDF, TXT, MD, JSON, YAML, code files) or image files to the prompt.
  - `/paste` or `/attach-clipboard`: Cross-platform clipboard extractor (PowerShell on Windows, `pngpaste`/`pbpaste` on macOS, `wl-paste`/`xclip` on Linux) supporting copied images (base64) or formatted text.
  - `/attachments`: Lists all currently queued attachments for the next prompt.
  - `/attach clear`: Clears the pending attachments queue.
  - Multi-modal support extended across OpenAI (`imageUrl`), Claude (`image.base64`), Gemini (`Part.bytes`), and `llamadart`.
- **Native Assets Build Support**:
  - Updated build pipeline to use `dart build cli` to package native C/C++ libraries alongside the `tealkit.exe` binary.

## 1.1.4

- **Dynamic Workspace Management (`/workspace`)**:
  - `/workspace set <directory_name>`: Dynamically sets the active working directory for the session. Rebinds all native file operations (`fs_find`, `fs_list_dir`, `fs_read_file`, `fs_write_file`, `fs_replace_text`, `terminal_exec`) to the specified base path and updates system prompts and instructions accordingly.
  - `/workspace`: Displays the current active base workspace directory, startup directory, and default status.
  - `/workspace clear` / `/workspace reset`: Resets the workspace directory back to the startup path.
- **Interactive Remote SSH Session Management (`/ssh`)**:
  - `/ssh connect <user:pwd@host[:port]>` or `<user@host[:port]>`: Overrides `ssh.yaml` in-memory for the current session and connects immediately to the remote server.
  - `/ssh`: Displays current SSH connection status, remote target host, and available SSH tools.
  - `/ssh disconnect`: Closes the active SSH connection and clears the session override, safely preserving preconfigured `ssh.yaml`.
- **Built-in Skill Tool Declarations**:
  - Added native built-in tools (`create_mermaid_png`, `calculate`, `sum_numbers`, `get_current_time`, `ssh_execute_command`, `ssh_list_directory`, `ssh_read_file`) directly into `cli/skills/` (`coding-agent-skill.md`, `dotnet-engineer-skill.md`, `dotnet-upgrade-skill.md`, `winforms-to-flutter-skill.md`).

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
