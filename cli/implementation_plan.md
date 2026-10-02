# Implementation Plan - MCP Uninstall Persistence, Tool Function Inspection/Filtering & Built-in Tools

Enhance TealKit CLI (`code_command.dart`, `mcp_manager_helper.dart`, and engine) to support proper filesystem uninstallation with `mcp.yaml` persistence, session-level tool function filtering (`/mcp_inspect`, `/mcp_enable_fnc`, `/mcp_reset_fnc`), and built-in TealKit MCP servers (`web_search`, `mermaid`, `toolbox`, `ssh`).

---

## 1. Requirements & User Specifications

1. **/uninstall <name|all_mcp>**:
   - For **local stdio servers**: uninstall the package from the filesystem (e.g. `npm uninstall -g <pkg>`, `uv tool uninstall <pkg>`, or directory deletion).
   - In **mcp.yaml**: switch the `enabled` flag to `false`.
   - For **remote servers (https://...)**: do not delete filesystem files; only toggle `enabled: false` in `mcp.yaml`.
   - Disconnect and unregister the MCP client from active session in memory.
   - When the user later re-enables a server in `mcp.yaml` and starts `tealkit code`, the server will be cleanly downloaded and re-installed.

2. **Dynamic Tool Filtering & Inspection**:
   - `/mcp_inspect <server_name>`: List all tools/functions provided by that server, their description, parameter schemas, and whether they are currently enabled.
   - `/mcp_enable_fnc <server_name> <fnc1,fnc2,...>`: Temporarily restrict the tools exposed to the agent LLM for that server to only the specified functions. (Temporal: active until `/bye`, CLI exit, or reset).
   - `/mcp_reset_fnc [server_name]`: Reset restrictions and re-expose all available functions for the server (or all servers).

3. **Built-in TealKit MCP Servers in CLI**:
   - `web_search`: Multi-provider web search (SerpApi, Serper, DuckDuckGo) configured via `web_search.yaml` (fallback to `.env` or auto DuckDuckGo).
   - `mermaid`: Diagram generator (`create_mermaid_png`) via Kroki PNG renderer.
   - `toolbox`: Utilities: `get_current_time`, `get_timezone_info`, `calculate`, `sum_numbers`, `geocode_city`.
   - `ssh`: Remote SSH/SFTP management (`execute_command`, `list_directory`, `read_file`, `upload_file`, `download_file`, `make_directory`, `remove_directory`, `list_scripts`, `run_script`) configured via `ssh.yaml`.

---

## 2. Proposed Changes

### A. MCP Uninstall & YAML Persistence (`lib/src/engine/mcp_manager_helper.dart`)
- Update `McpManagerHelper.uninstallServers`:
  - For local npm servers: run `npm.cmd uninstall -g <pkg>` (or `npm uninstall -g <pkg>`).
  - For local python/uv servers: run `uv tool uninstall <pkg>`.
  - For local directory venv servers: remove directory if applicable.
  - Load `mcp.yaml` (using `GlobalConfigLocator.resolveConfigFile('mcp.yaml')`), find matching server blocks by id or name, and update `enabled: false`.
  - Write back updated YAML cleanly.
  - Disconnect MCP client from `mcpManager`.

### B. Tool Inspection & Temporal Function Filtering (`lib/src/commands/code_command.dart` & `chat_command.dart`)
- Track an active function filter map: `final Map<String, Set<String>> mcpToolFilter = {};` (key: serverName or serverId, value: set of allowed tool names).
- Implement commands:
  - `/mcp_inspect <name>`: Finds client in `mcpManager.clients`, lists each tool with name, description, parameters, and whether it's enabled under `mcpToolFilter`.
  - `/mcp_enable_fnc <server> <func1,func2,...>`: Validates function names against server's actual tools, populates `mcpToolFilter[server]`, and recalculates active tools for LLM agent.
  - `/mcp_reset_fnc [server]`: Clears filter for specified server or all servers.
- When creating `Agent(...)` on each prompt turn:
  - Filter `mcpTools` / `allTools` passed to LLM so that only the allowed tool functions are visible to the agent.

### C. Built-in MCP Servers Integration (`lib/src/engine/builtin_mcp_servers.dart`)
- Create `BuiltinMcpServers`:
  - Loads `web_search.yaml` if present (`provider`, `api_key`, `max_results`). Exposes `web_search` tool.
  - Loads `ssh.yaml` if present (`host`, `port`, `username`, `password`, `private_key`). Exposes `ServerSshMcp` tools.
  - Exposes `mermaid` tool (`create_mermaid_png`).
  - Exposes `toolbox` tools (`get_current_time`, `get_timezone_info`, `calculate`, `sum_numbers`, `geocode_city`).
- Include built-in tools into `dartTools` or in-process MCP clients so they appear in `/tools`, `/mcp_inspect`, and are callable by the LLM.

### D. Update Documentation & Help
- Add `/mcp_inspect`, `/mcp_enable_fnc`, `/mcp_reset_fnc`, and details about `web_search.yaml` / `ssh.yaml` to `/help`, `README.md`, and `CHANGELOG.md`.

---

## 3. Verification Plan
1. Test `/uninstall <name>` and `/uninstall all_mcp`: verify `mcp.yaml` has `enabled: false`, package uninstall was triggered, and restarting `tealkit code` does not connect to uninstalled servers.
2. Test `/mcp_inspect <name>`, `/mcp_enable_fnc <server> <fnc>`, and verify only those tools are exposed to LLM.
3. Test `/mcp_reset_fnc <server>` to restore all tools.
4. Verify `web_search`, `mermaid`, `toolbox`, and `ssh` tool definitions and execution.
5. Compile `tealkit.exe` and test in live terminal.
