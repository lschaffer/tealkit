# Changelog - TealKit Coder for VS Code (`tealkit-vscode`)

All notable changes to the TealKit Coder extension will be documented in this file.

## 0.1.5

### RAG Mode, Dropdown & Approval Fixes, Scrollable Settings & Expanded Docs
- **Local RAG Mode (`📚 RAG`) & Search Tool (`rag_search`)**:
  - Added full `rag` mode support in the Chat mode selector and CLI RPC engine; automatically disables `📚 RAG (Not Configured)` when RAG is disabled or has no folder/web sources configured.
  - Added built-in `rag_search` tool querying `rag_index.db` directly and restricted `📚 RAG` mode to RAG/non-filesystem tools so models use the extracted RAG index instead of calling `fs_read_file` on binary `.docx`/`.pdf` files.
  - Fixed oversized activity-indicator popups caused by multi-line `AgentLogEvent` prompt dumps.
- **LLM Dropdown, Tool Approvals & Scrollable Settings**:
  - Fixed LLM profile dropdown becoming empty when selecting non-default profiles (`model_changed` now syncs by profile name).
  - Fixed **⚡ Always Allow** on tool approval cards so wrapped `mcp_call_tool` calls unwrap inner tool names/risks, persist auto-approval settings across both `permissions.yaml` and `config.yaml`, and sync checkboxes in the Settings tab.
  - Enabled scrolling on `#panel-settings` and all configuration tabs (`#panel-llms`, `#panel-mcp`, `#panel-skills`, `#panel-memory`, `#panel-server`).
- **Skills & Documentation**:
  - Fixed `(no description)` in the Skills tab by hardening frontmatter parsing.
  - Updated starter coding skills with Git verification/commit workflow instructions.
  - Expanded `README.md` with Mermaid architecture diagram, operating modes, parameter tables, and step-by-step RAG guide, and added MIT `LICENSE` for VS Code Marketplace publishing.

## 0.1.4

### Configuration, MCP Tool Discovery, RAG Settings & Server Workflow Controls
- **LLM Profile Editor (`llm.yaml`)**:
  - Enabled editing and renaming the **Profile Name** for existing LLM profiles while preserving profile order and updating the default profile reference if renamed.
  - Added **🔌 Test API** connection button and status badge directly in the LLM Profile modal.
- **MCP Server Testing & Tool Discovery (`mcp.yaml`)**:
  - Enabled renaming existing MCP servers in the Edit MCP Server modal.
  - Added **🔍 Test / Show Tools** action both in the Edit MCP Server modal and on every MCP Server card to spawn the MCP server over stdio, perform JSON-RPC `initialize` + `tools/list`, and display all discovered tools and descriptions.
  - Automatically reloads MCP servers in the active RPC engine when saving, toggling, or deleting servers.
- **Full `config.yaml` Synchronization, Checkboxes & Local RAG Settings**:
  - Synchronized all generic settings, checkboxes (`agent.planning`, `compact_tools`, `prompt.multiline`, `prompt.auto_paste_images`, `session.auto_save`, `permissions.auto_approve_*`, `rag.enabled`), and `agent.max_tool_iterations` between the Settings view and `config.yaml`.
  - Added full **RAG Configuration** section in the Settings view (`database_path`, `sources.folders`, `sources.web`, `sources.max_pages`, `file_extensions`, `chunking`, `embedding`, and `search` parameters).
  - Auto-saves and reloads `config.yaml` in the RPC engine whenever any setting or checkbox is changed, and live-reloads the Settings UI when `config.yaml` is edited in VS Code.
- **TealKit Server Profiles & Remote Workflow Status / Logs (`server.yaml`)**:
  - Added **Edit** (including profile renaming) and **🔌 Test** connection buttons to each TealKit Server profile card and modal.
  - Added live workflow execution status badges (`IDLE`, `🔄 RUNNING`, `✔ COMPLETED`, `✖ FAILED`), automatic status polling, **⏹ Stop** cancellation, and **📋 Fetch Logs** viewer for remote scheduled workflows.

## 0.1.3

### Stability & Multi-Turn Fixes
- **Human-in-the-Loop Tool Approval**:
  - Fixed permission request/response protocol key mismatches (`id`/`requestId`, `approved`/`allowed`) between `agentProcess.ts` and `TealKitRpcEngine`.
  - Added full interactive `.approval-card` UI in chat with `Approve`, `Always Allow`, and `Reject` buttons.
  - Implemented `_cancelPendingPermissions()` and prompt cancellation unblocking to prevent the engine from freezing on tool approval.
- **Sequential Tool Result & Assistant Rendering**:
  - Fixed assistant response placement after tool executions so results render cleanly below tool summary cards instead of above or disappearing.
  - Handled `done` event fallback rendering if chunks are not streamed.
- **Context Compression Safeguards**:
  - Raised context compression threshold safeguards in RPC engine to prevent repeated compression loops and formatting errors with long system prompts.
- **Smooth Chat Scrolling**:
  - Enforced uncompressed scrollable chat thread with styled scrollbar and `scroll-behavior: smooth`.

## 0.1.2

- **Fix Webview Initialization**:
  - Added `bundledDependencies: ["yaml"]` to ensure runtime YAML parser is properly bundled into the VSIX distribution package, resolving `Cannot find module 'yaml'` extension activation failure on clean installations.

## 0.1.1

### Features & UI Enhancements
- **Generic CLI Settings Panel**:
  - Restored and populated the dedicated **Settings** tab.
  - Allows editing CLI configuration directly from the UI: `max_turns`, `max_tool_iterations`, `planning`, `compact_tools`, `compression_threshold`, and `auto_paste_images`.
  - Added one-click **Open config.yaml** button to open the workspace configuration file in the VS Code editor.
  - Removed redundant top-right header gear button in favor of the clean tab navigation.
- **Extended LLM Hyperparameters**:
  - Added full hyperparameter configuration to the Add/Edit Profile modal: `temperature`, `max_tokens`, `context_size`, `top_p`, `top_k`, `repeat_penalty`, `is_slm`, `thinking`, and `use_streaming`.
  - Integrated **Load Models** and **Test API** actions.
- **One-Click Clipboard Copying**:
  - Added copy buttons with visual feedback (`✓ Copied!`) to:
    - User prompt bubbles
    - Assistant response messages
    - Rendered Markdown code blocks
    - Tool execution output cards
- **Chat Layout & Fluid Vertical Scrolling**:
  - Fixed flexbox layout where messages and tool cards collapsed vertically into thin horizontal bars.
  - Enforced `flex-shrink: 0` on all cards and message bubbles with `overflow-y: auto` on the message container.
  - Added live elapsed timer to the thinking/activity indicator (`Agent thinking... (14s)`).
- **Session Management**:
  - Clicking the **+** (New Session) button in the chat header now immediately clears the current conversation view and starts a fresh turn.

### Bug Fixes
- Fixed RPC stdout streaming events and watchdog timeouts during long model thinking phases.
- Sanitized message formatting to prevent `BadRequestException: can only concatenate str (not "NoneType") to str` when executing multi-turn tool loops.

---

## 0.1.0

- **Initial Release of TealKit Coder for VS Code**:
  - Autonomous AI Coding Agent powered by `tealkit.exe rpc`.
  - Interactive sidebar webview with **Chat**, **LLMs**, **MCP Tools**, **Skills**, **Memory**, and **Server** views.
  - Side-by-side interactive Git diff viewer for reviewing proposed file changes before acceptance.
  - Real-time agent event streaming with Markdown formatting and syntax-highlighted code blocks.
  - Sub-agent and tool permission approval prompts.

