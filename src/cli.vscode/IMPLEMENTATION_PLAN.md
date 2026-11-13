# TealKit VS Code / Antigravity Extension — Architectural & Implementation Plan

**Extension Identifier:** `tealkit.tealkit-vscode`  
**Display Name:** TealKit AI Coding Agent  
**Engine:** `tealkit_cli` (Dart Native Native Executable)

---

## 1. Executive Summary & Architectural Decisions

### 1.1 `stdio` (JSON-RPC / NDJSON) vs. `HTTP REST`
| Criterion | `stdio` (Child Process via stdin/stdout) | `HTTP REST` / SSE / WebSocket Daemon |
| :--- | :--- | :--- |
| **Reliability** | **Highest.** Sub-process lifecycle is hard-bound to VS Code. If VS Code is closed or reloaded, the process terminates immediately without leftover zombie processes. | **Lower.** Daemon processes often survive IDE crashes/restarts, leading to port conflicts and orphaned RAM usage. |
| **Multi-Workspace** | **Zero-effort.** Each workspace window spawns its own isolated CLI instance with its own root directory and session context. | **Complex.** Requires dynamic port assignment (`--port 0`), port discovery, and coordination between windows. |
| **Security & Firewall** | **Zero friction.** Does not open any network ports; no Windows Defender Firewall alerts; safe from local browser port-scanning attacks. | **Vulnerable without tokens.** Any local website in a browser could hit `http://localhost:<port>/execute_code` unless guarded by auth tokens. |
| **Performance** | Zero network socket overhead; instant streaming via standard pipes. | Minor HTTP / TCP loopback overhead. |

> **Decision:**  
> Use **`stdio` (Line-delimited JSON / JSON-RPC 2.0)** as the primary, default communication mode.  
> Support an optional `"tealkit.remoteServerUrl"` setting for users who wish to offload agent execution to an external `tealkit-server` or GPU instance over HTTP/WebSocket.

---

### 1.2 Analysis of Heavy Dependencies (DuckDB & LlamaDart)

#### DuckDB Status in Local CLI:
- **Verified:** The local `tealkit_cli` does **NOT** use DuckDB.
- Local CLI RAG utilizes native `sqlite3` (`rag_index.db`).
- DuckDB is strictly utilized in `tealkit-server` and the Flutter desktop/mobile app for hybrid analytics. Therefore, local CLI has zero DuckDB overhead.

#### LlamaDart & Embedded Model Overhead:
- When compiled with embedded model support, `tealkit_cli` bundles **23 native asset DLLs** (`llamadart.dll`, `ggml-vulkan.dll`, `LiteRtLm.dll`, `dxcompiler.dll`, `pdfium.dll`, etc.), totaling **~52 MB of DLLs** and a **~67 MB zip archive**.
- Most developers use **Ollama**, **llama.cpp server**, or Cloud APIs (**Claude 3.7**, **OpenAI**, **Gemini**, **DeepSeek**, **OpenRouter**). For these users, embedded GGUF runtime libraries are unnecessary dead weight.

#### Solution: Two Distribution Flavors
1. **`tealkit-lite` (Recommended Default for VS Code):**
   - Stripped of `llamadart` and `pdfium_dart` native assets.
   - Relies on Ollama, llama.cpp server, OpenAI-compatible local endpoints, or Cloud LLMs.
   - **Result:** A single, standalone native executable under **15 MB** with **zero external DLL dependencies**. Installs in seconds.
2. **`tealkit-full` (Self-Contained Embedded):**
   - Bundles all 23 native DLLs for fully offline, zero-configuration local execution with embedded GGUF models.

---

## 2. Changes Required in `tealkit_cli` (Phase 1)

Before writing the TypeScript extension, `tealkit_cli` must expose a headless RPC interface.

### 2.1 Add RPC Subcommand / Flag: `tealkit code --rpc`
Currently, `CodeCommand` operates in an interactive terminal mode (`stdin.readLineSync()`, ANSI colors, terminal spinners).  
In RPC mode:
1. **Stdout Cleanliness Guarantee:**
   - **All** diagnostic prints, debug logs, and notices must be diverted to `stderr` or a log file (`~/.config/tealkit/tealkit_rpc.log`).
   - `stdout` is **strictly reserved** for line-delimited JSON messages (`\n`).
2. **Inbound Protocol (TypeScript Extension -> CLI `stdin`):**
   ```json
   {"action": "prompt", "prompt": "Refactor auth.ts to async/await", "contextFiles": ["src/auth.ts"]}
   {"action": "cancel"}
   {"action": "set_mode", "mode": "code"} // "architect" | "code" | "ask"
   {"action": "set_model", "profile": "claude-3-7-sonnet"}
   {"action": "permission_response", "requestId": "req_123", "allowed": true}
   {"action": "get_status"}
   {"action": "list_skills"}
   {"action": "list_mcp_tools"}
   ```
3. **Outbound Protocol (CLI `stdout` -> TypeScript Extension):**
   ```json
   {"event": "status", "mode": "code", "model": "claude-3-7-sonnet", "mcpCount": 5, "skillCount": 4}
   {"event": "chunk", "text": "Thinking..."}
   {"event": "tool_call", "id": "call_1", "name": "fs_read_file", "args": {"path": "src/auth.ts"}}
   {"event": "tool_result", "id": "call_1", "output": "export function login() { ... }"}
   {"event": "permission_request", "requestId": "req_123", "tool": "fs_write_file", "args": {"path": "src/auth.ts"}}
   {"event": "diff", "path": "src/auth.ts", "oldContent": "...", "newContent": "..."}
   {"event": "done", "usage": {"inputTokens": 1200, "outputTokens": 350}}
   {"event": "error", "message": "Failed to connect to provider"}
   ```

### 2.2 Dedicated `tealkit-lite` Build Target
Create a minimal entrypoint `cli/bin/tealkit_lite.dart` or conditionally exclude `llamadart` via build tags/configurations:
- Compiles via `dart compile exe bin/tealkit_lite.dart -o build/tealkit-lite.exe`.
- Resulting binary is portable and self-contained.

---

## 3. VS Code Extension Architecture (`tealkit.vscode`)

```
tealkit.vscode/
├── package.json                   # Extension manifest, contributes views, commands, configuration
├── tsconfig.json                  # TypeScript compiler settings
├── src/
│   ├── extension.ts               # Activation, command registration, lifecycle management
│   ├── process/
│   │   ├── tealkit_process.ts     # Spawns CLI, manages stdio pipes, NDJSON parsing
│   │   └── binary_resolver.ts    # Locates bundled or downloaded tealkit executable
│   ├── views/
│   │   ├── chat_view_provider.ts  # WebviewViewProvider for the sidebar
│   │   └── diff_manager.ts        # Handles vscode.diff and applying edits
│   ├── config/
│   │   ├── config_watcher.ts      # Hot-reloads on .tealkit/config.yaml edits
│   │   └── secret_storage.ts      # Manages API keys in OS Keychain via context.secrets
│   └── participant/
│       └── chat_participant.ts    # Native VS Code @tealkit Chat Participant handler
├── webview-ui/                    # Lightweight Webview UI (Svelte / Preact / Vanilla HTML+CSS)
│   ├── index.html
│   ├── main.ts
│   └── style.css
└── schemas/
    ├── tealkit-config.schema.json # JSON Schema for autocomplete in config.yaml
    └── tealkit-mcp.schema.json    # JSON Schema for mcp.yaml
```

---

## 4. UI Specification: Inspired by `llama.vscode`

The user experience should be clean, fast, and unencumbered by excessive boilerplate:

1. **Header Toolbar:**
   - Active Model Dropdown (reads directly from `llm.yaml` profiles).
   - Mode Selector Pills: `[💻 Code]` `[📐 Plan]` `[💬 Ask]`.
   - Status indicators: `[5 MCPs]` `[3 Skills]`.
   - Settings Gear icon opening `.tealkit/config.yaml`.
2. **Chat Stream:**
   - Clean markdown formatting.
   - Collapsible tool execution cards showing tool name, parameters, and execution time.
   - Subagent delegation tags (e.g. `[Delegated to Research Agent]`).
3. **Interactive Diff Approval:**
   - Instead of blindly overwriting files, show an interactive card:
     ```text
     ┌──────────────────────────────────────────────────┐
     │ 🔀 src/services/auth_service.ts (+14 -8)         │
     │ [ Review Diff ]   [ Accept (Enter) ]   [ Reject ] │
     └──────────────────────────────────────────────────┘
     ```
   - Clicking **Review Diff** opens VS Code's native side-by-side diff editor (`vscode.diff`).

---

## 5. Deployment Strategies

### Strategy A: Runtime Download (Recommended for Small Initial VSIX)
1. The extension `.vsix` is ultra-light (~200 KB).
2. On first launch, the extension checks if `tealkit` is available on system `PATH` or in `~/.tealkit/bin/`.
3. If not found, it displays a prompt:
   *"TealKit CLI engine is needed. Download tealkit-lite (~12 MB)? [Download Now]"*
4. Downloads the platform-specific precompiled binary from `https://tealkit.dev/download/tealkit-lite-<os>-<arch>` into `context.globalStorageUri`.

### Strategy B: Pre-bundled Platform VSIXs
1. Publish platform-specific VSIXs to the VS Code Marketplace:
   - `tealkit-vscode-win32-x64.vsix`
   - `tealkit-vscode-linux-x64.vsix`
   - `tealkit-vscode-darwin-arm64.vsix`
2. Users download a zero-setup extension that works out of the box offline.

---

## 6. Execution Roadmap

1. **Phase 1: CLI Headless Protocol (`tealkit_cli`)**
   - Implement `tealkit code --rpc` in Dart.
   - Route logs to `stderr` and JSON protocol to `stdout`.
   - Add `tealkit-lite` build configuration without `llamadart`.
2. **Phase 2: TypeScript Shim & Process Manager**
   - Setup `tealkit.vscode` scaffold with TypeScript.
   - Implement `TealKitProcess` with robust readline NDJSON parsing and error recovery.
3. **Phase 3: Webview UI & Diff Integration**
   - Create the sidebar UI modeled on `llama.vscode`.
   - Connect prompt streaming and native `vscode.workspace.applyEdit`.
4. **Phase 4: Packaging & Release**
   - Build automated packaging script in GitHub Actions / local PowerShell.
   - Publish to VS Code Marketplace & Open-VSX.

