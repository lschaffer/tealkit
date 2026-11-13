# TealKit Coder for VS Code (`tealkit.vscode`)

An autonomous, multi-agent coding and research extension for **Visual Studio Code** and **Google Antigravity**, powered by the native **TealKit CLI (`tealkit.exe`)** engine.

TealKit Coder brings full repository exploration, surgical file editing, automated terminal verification, Model Context Protocol (MCP) tools, reusable Agent Skills, local Retrieval-Augmented Generation (RAG), episodic memory compression, and remote TealKit Server workflow orchestration directly into your IDE sidebar.

---

## 1. End-to-End Architecture

Instead of relying on a single stateless chat loop inside the extension host, `tealkit.vscode` runs a persistent headless **TealKit RPC Engine** (`tealkit rpc --workspace <dir> --mode <mode> --auto-save-session --continue`) over newline-delimited JSON-RPC (`stdio`) and synchronizes all settings with `~/.tealkitcoder/`.

```mermaid
flowchart TB
    subgraph VSCode["VS Code / Antigravity IDE"]
        direction TB
        subgraph Webview["TealKit Sidebar Webview (7 Tabs)"]
            TabChat["💬 Chat & Diff Review"]
            TabLLMs["🤖 LLMs Manager"]
            TabMCP["🔌 MCP Tools & Tester"]
            TabSkills["🧩 Agent Skills"]
            TabMemory["🧠 Memory & Sessions"]
            TabServer["☁️ Remote Server & Workflows"]
            TabSettings["⚙️ Generic & RAG Settings"]
        end

        subgraph ExtHost["Extension Host (TypeScript)"]
            ChatProvider["TealKitChatViewProvider"]
            YamlMgr["TealKitYamlConfigManager\n(FileWatchers + YAML Sync)"]
            DiffMgr["TealKitDiffManager\n(VS Code Diff & Inline Review)"]
            AgentProc["TealKitAgentProcess\n(JSON-RPC Client over stdio)"]
        end
    end

    subgraph ConfigDir["Shared User Configuration (~/.tealkitcoder)"]
        CfgYaml["config.yaml & permissions.yaml"]
        LlmYaml["llm.yaml (Profiles & API Keys)"]
        McpYaml["mcp.yaml (External MCP Servers)"]
        SrvYaml["server.yaml (Remote Server Profiles)"]
        SkillsDir["skills/*.md (Agent Skills)"]
        RagDb["rag_index.db (SQLite / FTS5 + Vector Index)"]
    end

    subgraph CliEngine["TealKit Native CLI Engine (tealkit.exe rpc)"]
        RpcLoop["RPC Command Dispatcher & Turn Orchestrator"]
        ModeRouter["Mode Router\n(Code | Architect | Ask | RAG)"]
        NativeTools["Built-in Coding & OS Tools\n(fs_*, terminal_exec, web_search, ssh_*)"]
        McpClient["External MCP Client\n(stdio / SSE / Streamable HTTP)"]
        RagEngine["Local RAG Service\n(Folder + Web Crawler + Hybrid Search)"]
        SessionStore["Session & Episodic Memory Store\n(.tealkit/sessions & .tealkit/memory)"]
    end

    subgraph External["External Providers & Infrastructure"]
        LLMProviders["Cloud & Local LLMs\n(OpenAI, Anthropic, Gemini, Mistral,\nDeepInfra, OpenRouter, Ollama, GGUF)"]
        TealKitServer["Remote TealKit Server\n(Scheduled & On-Demand Workflows)"]
    end

    Webview <-->|postMessage| ChatProvider
    ChatProvider <--> YamlMgr
    ChatProvider <--> DiffMgr
    ChatProvider <--> AgentProc
    YamlMgr <-->|Live Read/Write & Watch| ConfigDir
    AgentProc <-->|JSON-RPC (stdin/stdout)| RpcLoop
    RpcLoop --> ModeRouter
    RpcLoop <--> NativeTools
    RpcLoop <--> McpClient
    RpcLoop <--> RagEngine
    RpcLoop <--> SessionStore
    RagEngine <--> RagDb
    RpcLoop <--> LLMProviders
    RpcLoop <--> TealKitServer
```

---

## 2. Operating Modes

You can switch the agent's operating mode at any time using the **Mode Selector** dropdown at the top-left of the **Chat** tab, or via slash commands.

| Mode | Selector Label | Mutating Tools (`fs_write_file`, `fs_replace_text`, `terminal_exec`) | Primary Purpose & Behavior |
| :--- | :--- | :---: | :--- |
| **Code** | `💻 Code` | ✅ **Enabled** (except `tasks.md` unless planning) | **Default implementation mode.** Explores the codebase, makes surgical code edits (`fs_replace_text`, `fs_write_file`), executes compiler/test suites (`terminal_exec`), and verifies changes. |
| **Architect** | `📐 Architect` | 📝 **`tasks.md` & `docs/` only** | **Design & planning mode.** Investigates project structure, analyzes requirements, and creates or updates `tasks.md` checklists and architectural plans without modifying production source files. |
| **Ask** | `💬 Ask` | 🔒 **Read-Only** | **Safe Q&A and code review mode.** Reads files (`fs_read_file`, `fs_list_dir`, `fs_find`) and answers questions or explains code with zero risk of modifying files or running shell commands. |
| **RAG** | `📚 RAG` | 🔒 **Read-Only + Auto-RAG Retrieval** | **Knowledge base & documentation mode.** Automatically queries your local RAG index (`rag_index.db`) before every turn, injects the highest-scoring document/web chunks with source citations into the prompt, and answers grounded in your indexed sources. *(Note: If RAG is disabled or has no configured folder/web sources in **Settings**, the `📚 RAG` option is automatically disabled in the selector.)* |

---

## 3. Sidebar Navigation Tabs & How to Use Them

The TealKit Coder sidebar is organized into **7 dedicated tabs** (all configuration tabs support vertical scrolling and instant YAML synchronization):

### 💬 1. Chat Tab
- **Mode & Model Bar**: Select the active mode (`💻 Code`, `📐 Architect`, `💬 Ask`, `📚 RAG`) and switch between any configured **LLM Profile** on the fly.
- **Attached Skills Bar**: View active skills attached to the current session as removable chips (`🧩 coding-agent-skill ✕`) or click **`+ Attach`** to attach additional skills.
- **Tool Execution & Approval Cards**:
  - Expandable tool cards show tool input/output with a **Copy Output** button.
  - When a tool requires permission, an interactive **Tool Approval Required** card appears with three choices:
    - **`✓ Approve`**: Allow this single tool invocation.
    - **`⚡ Always Allow`**: Approve this tool and automatically enable auto-approval for its risk category (`read`, `write`, `execute`, or `network`) in both the live engine and `config.yaml` / `permissions.yaml` so subsequent calls with different parameters proceed without interrupting your flow.
    - **`✕ Reject`**: Block the tool call.
- **Session Persistence**: Switching to other VS Code views (Explorer, Source Control, Debug) and back **preserves your active chat state**, including in-progress streaming turns. Use the **History (`🕒`)** button to browse, reload, or delete previous workspace sessions.

<!-- Screenshot placeholder: Chat Tab & Tool Approval -->

### 🤖 2. LLMs Tab (`llm.yaml`)
- Manage all LLM profiles stored in `~/.tealkitcoder/llm.yaml`.
- **Add / Edit / Clone / Delete Profiles**: Both the **Profile Name** and all model parameters are editable.
- **Load Models (`🔍 Load Models`)**: Queries the provider's `/v1/models` endpoint using your Base URL and API Key to populate the Model ID dropdown automatically.
- **Test API Connection (`⚡ Test API Connection`)**: Verifies credentials and model reachability with latency reporting before saving.
- **Set Default**: Marks the profile as `default_llm` in `llm.yaml`.

<!-- Screenshot placeholder: LLM Profile Editor -->

### 🔌 3. MCP Tools Tab (`mcp.yaml`)
- Configure external **Model Context Protocol (MCP)** servers (`stdio` command/args/env).
- **Test & Show Tools (`🔍 Test / Tools`)**: Spawns the MCP server, performs the JSON-RPC `initialize` + `tools/list` handshake, and displays every discovered tool name and description directly on the server card or inside the modal.

<!-- Screenshot placeholder: MCP Tools Tab -->

### 🧩 4. Skills Tab (`~/.tealkitcoder/skills/*.md`)
- Lists all Markdown-based Agent Skills with their frontmatter description and attachment status (`ATTACHED` / `Available`).
- Attach or detach skills from the live coding session with one click, create new skills via **`+ New Skill`**, or click **`Open in Editor`** to edit the `.md` file directly in VS Code.
- Built-in skills (`coding-agent-skill`, `dotnet-engineer-skill`) include instructions to check if **Git** is configured in the workspace and automatically stage and commit verified changes (`git add` / `git commit`) upon completing tasks.

<!-- Screenshot placeholder: Skills Tab -->

### 🧠 5. Memory Tab (`.tealkit/sessions` & `.tealkit/memory`)
- **Saved Chat Sessions**: Resume previous conversations (`▶ Load / Continue`), inspect raw session JSON (`📄 Open JSON`), or delete old sessions.
- **Episodic Memory Archives**: When a conversation exceeds `compression_threshold`, older turns are summarized and archived into `.tealkit/memory/`. You can also trigger **`⚡ Archive Current Session Now`** manually.

### ☁️ 6. Server Tab (`server.yaml`)
- Manage connections to remote **TealKit Server** instances (`https://...` or `http://localhost:8085`).
- **Test Connection (`🔌 Test`)**: Pings `/api/health` and `/api/workflows` to verify server status and latency.
- **Remote Workflows**: Lists all workflows on the active server with live status badges (`IDLE`, `🔄 RUNNING`, `✔ COMPLETED`, `✖ FAILED`), **`▶ Run Workflow`**, **`⏹ Stop`**, **`🔄 Status`**, and **`📋 Fetch Logs`** to inspect execution output directly inside VS Code.

<!-- Screenshot placeholder: Remote Server & Workflows Tab -->

### ⚙️ 7. Settings Tab (`config.yaml`)
- Full two-way synchronization with `~/.tealkitcoder/config.yaml`. Changing any field automatically saves to `config.yaml` and hot-reloads the running CLI engine.

<!-- Screenshot placeholder: Settings Tab -->

---

## 4. Configuration & Parameters Reference

All configuration files live in `~/.tealkitcoder/` (or workspace-local `.tealkit/`). Below is the complete reference for all parameters available in the **Settings** and **LLMs** tabs.

### 4.1 Execution & Session Limits (`config.yaml`)

| UI Setting | YAML Key | Default | Description |
| :--- | :--- | :---: | :--- |
| **Max Session Turns** | `session.max_turns` | `500` | Maximum conversation turns retained in a single session file before rotation. |
| **Max Session Size (MB)** | `session.max_size_mb` | `10` | Maximum file size (in MB) for a saved session JSON snapshot. |
| **Max Tool Iterations** | `agent.max_tool_iterations` | `100` | Maximum sequential tool-call loops allowed per user prompt before the agent pauses. |
| **Progressive Tool Discovery** | `agent.progressive_discovery` | `auto` | Controls how tools are exposed to the LLM (`auto`, `on`, `off`). In `auto` mode, native coding tools are always exposed directly; meta-tools (`mcp_list_tools`, `mcp_call_tool`) are used only when 20+ external MCP tools are active. |
| **Auto-Save Session History** | `session.auto_save` | `true` | Automatically saves conversation turns after every prompt so sessions persist across IDE restarts (`--auto-save-session`). |

### 4.2 Context, Planning & Prompt (`config.yaml`)

| UI Setting | YAML Key | Default | Description |
| :--- | :--- | :---: | :--- |
| **Compression Threshold (tokens)** | `agent.compression_threshold` | `4000` | Token count threshold at which older conversation turns are compressed into Episodic Memory. |
| **CLI Submit Key** | `prompt.submit_key` | `enter` | Key binding for submitting prompts in terminal REPL mode (`enter` or `ctrl+enter`). |
| **Enable Planning Phase** | `agent.planning` | `true` | Allows the agent to create/maintain `tasks.md` checklists before executing complex multi-file changes. |
| **Compact Tool Schemas** | `compact_tools` | `true` | Minifies JSON Schema descriptions sent to the LLM to reduce token consumption and latency. |
| **Multiline CLI Prompt Input** | `prompt.multiline` | `false` | Enables multiline input mode by default in the interactive CLI REPL. |
| **Auto-Paste Clipboard Images** | `prompt.auto_paste_images` | `true` | Allows attaching clipboard screenshots directly into vision-capable LLM prompts. |

### 4.3 Tool Auto-Approval Permissions (`config.yaml` & `permissions.yaml`)

| UI Setting | YAML Key | Default | Tools Covered |
| :--- | :--- | :---: | :--- |
| **Auto-Approve Read Tools** | `permissions.auto_approve_read` | `true` | `fs_read_file`, `fs_list_dir`, `fs_find`, `rag_search`, `mcp_list_tools`, time/math utilities. |
| **Auto-Approve Write / File Edit Tools** | `permissions.auto_approve_write` | `false` | `fs_write_file`, `fs_replace_text`, `create_mermaid_png`. |
| **Auto-Approve Terminal Execution** | `permissions.auto_approve_execute` | `false` | `terminal_exec`, `ssh_execute_command`, `ssh_upload_file`. |
| **Auto-Approve Network / Web Tools** | `permissions.auto_approve_network` | `false` | `web_search`, `web_fetch`, external MCP tool calls (`mcp_call_tool` on remote servers). |

### 4.4 LLM Profile Parameters (`llm.yaml`)

| Parameter | YAML Key | Default | Description |
| :--- | :--- | :---: | :--- |
| **Provider** | `provider` | `openai_compatible` | `openai_compatible`, `openai`, `anthropic`, `google` (Gemini), `mistral`, `ollama`, `openrouter`, `deepinfra`, or `llamadart` (local GGUF). |
| **Model ID** | `model` | — | Provider model identifier (e.g., `claude-3-7-sonnet-20250219`, `Qwen/Qwen3-Coder-480B-A35B-Instruct`, `qwen2.5-coder:14b`). |
| **Base URL** | `base_url` | *(provider default)* | Custom API endpoint (e.g., `https://api.deepinfra.com/v1/openai` or `http://localhost:11434`). |
| **API Key** | `api_key` | *(from ENV)* | API key or environment variable placeholder (`${OPENAI_API_KEY}`). |
| **Temperature** | `temperature` | `0.2` | Sampling temperature (`0.0` = deterministic coding, `0.7+` = creative). |
| **Max Tokens** | `max_tokens` | `8192` | Maximum output tokens generated per response. |
| **Context Size** | `context_size` | `32768` | Context window size in tokens (used for local Ollama / GGUF allocation and token budgeting). |
| **Top P / Top K / Repeat Penalty** | `top_p`, `top_k`, `repeat_penalty` | *(optional)* | Advanced sampling hyperparameters. |
| **SLM / Thinking / Streaming** | `is_slm`, `thinking`, `use_streaming` | `false` / `false` / `true` | Optimizes prompts for Small Language Models (`is_slm`), enables reasoning tokens (`thinking`), or toggles token streaming (`use_streaming`). |

---

## 5. Local RAG (Retrieval-Augmented Generation): Configuration & Usage Guide

TealKit Coder includes a built-in **Local RAG Engine** backed by SQLite FTS5 keyword search and dense vector embeddings (`rag_index.db`). You can index local documentation folders (`.md`, `.txt`, `.pdf`, `.docx`, `.csv`, `.json`) and documentation websites, then query them using **Hybrid Search (Reciprocal Rank Fusion)**.

> [!NOTE]
> By default, a fresh installation starts with **empty** `folders` and `web` lists so no external URLs or folders are indexed unless you explicitly configure them. When no RAG sources are configured, the `📚 RAG` mode option in the Chat dropdown is disabled (`📚 RAG (Not Configured)`).

### Step 1: Configure RAG Sources in the Settings Tab (or `config.yaml`)

1. Open the **`⚙️ Settings`** tab in the TealKit sidebar and scroll down to **RAG (Retrieval-Augmented Generation) Settings**.
2. Check **`☑ Enable Local RAG Indexing & Search (rag.enabled)`**.
3. Configure your sources:
   - **Document Folder Sources (`rag.sources.folders`)**: Enter one folder path per line (absolute or workspace-relative), for example:
     ```text
     C:\projects\my_app\docs
     C:\specs\architecture_pdfs
     ```
   - **Web Crawl Sources (`rag.sources.web`)**: Enter one starting URL per line, for example:
     ```text
     https://docs.example.com/api
     ```
4. Choose your **Embedding Provider (`rag.embedding.provider`)**:
   - **`embedded`** *(Default — Zero configuration)*: Uses fast, deterministic local feature-hash embeddings (384-dim) combined with SQLite FTS5 BM25 keyword search. Requires no external server or API key.
   - **`ollama`**: Uses a local Ollama embedding model (e.g., `nomic-embed-text` at `http://localhost:11434`).
   - **`openai`**: Uses an OpenAI-compatible `/v1/embeddings` endpoint (e.g., `text-embedding-3-small`).
5. Click **`💾 Save & Sync Settings`** (or simply unfocus the field — settings auto-save to `config.yaml`).

Equivalent section in `~/.tealkitcoder/config.yaml`:

```yaml
rag:
  enabled: true
  database_path: rag_index.db
  sources:
    folders:
      - C:\projects\my_app\docs
      - C:\specs\architecture_pdfs
    web:
      - https://docs.example.com/api
    max_pages: 50
    file_extensions: [".txt", ".md", ".pdf", ".docx", ".csv", ".json"]
  chunking:
    chunk_size: 1000
    chunk_overlap: 150
  embedding:
    provider: ollama
    model: nomic-embed-text
    base_url: http://localhost:11434
  retrieval:
    search_mode: hybrid   # hybrid | vector | keyword
    max_chunks: 5
    min_score: 0.15
```

### Step 2: Build or Refresh the RAG Index

Once your folders or web URLs are configured, build the local index directly from the **Chat** tab using the `/reindex` (or `/rag index`) slash command:

```text
/reindex
```

**Example Output in Chat:**
```text
🔄 Indexing configured RAG sources (2 folder(s), 1 web URL(s))...
✔ RAG indexing complete: 42 sources, 318 chunks indexed (0 errors).
```

To check index statistics at any time, run:
```text
/rag status
```

### Step 3: Query Your Knowledge Base (3 Ways)

#### Option A: Switch to `📚 RAG` Mode (Recommended for Doc Q&A)
1. Select **`📚 RAG`** from the Mode dropdown at the top of the Chat tab.
2. Ask any question in natural language:
   ```text
   How is the MQTT sensor payload authenticated according to the gateway specification, and which error codes are returned on token expiry?
   ```
3. **What happens under the hood**:
   - Before calling the LLM, TealKit automatically runs a hybrid search across `rag_index.db` for your prompt.
   - The top matching chunks (`max_chunks`, default `5`) above `min_score` are injected into the turn context with their exact file path or URL.
   - The assistant answers your question and cites the `[Source: ...]` documents.

#### Option B: Direct Search via `/rag search <query>`
If you want to inspect the raw retrieved chunks and relevance scores without running a full LLM turn, type:
```text
/rag search MQTT authentication token expiry
```
TealKit returns the ranked document chunks, scores, and source paths immediately in the chat window.

#### Option C: Use RAG Together with `💻 Code` Mode
Even while working in **`💻 Code`** mode, you can reference findings from your RAG index to implement features:
1. Ask a question in **`📚 RAG`** mode to retrieve the specification or API contract into the session history.
2. Switch the dropdown to **`💻 Code`** mode and prompt:
   ```text
   Now implement the MQTT token refresh handler in src/mqtt_client.dart following the specification above and run unit tests.
   ```

---

## 6. Slash Commands Quick Reference

Type any of the following slash commands directly into the **Chat** input box:

| Slash Command | Description |
| :--- | :--- |
| `/plan <task>` | Temporarily switches to **Architect** mode for this turn to design or update `tasks.md`. |
| `/rag status` | Shows current RAG configuration, database path, and number of indexed sources & chunks. |
| `/rag index` or `/reindex` | Crawls all configured `rag.sources.folders` and `rag.sources.web` URLs and updates `rag_index.db`. |
| `/rag search <query>` | Performs a direct hybrid/vector/keyword search against `rag_index.db` and prints the top matching chunks. |
| `/rag clear` | Clears all indexed documents and chunks from `rag_index.db`. |
| `/llm <profile_name>` | Switches the active LLM profile for the current session. |
| `/skills` | Opens the **Skills** tab to manage or attach agent skills. |
| `/skill attach <name>` | Attaches a skill (e.g. `/skill attach coding-agent-skill`) to the active session. |
| `/skill detach <name>` | Detaches a skill from the active session. |
| `/archive` | Compresses and archives the current conversation into Episodic Memory (`.tealkit/memory/`). |

---

## 7. Building & Packaging the Extension

```bash
cd cli.vscode
npm install
npm run compile
npx vsce package
```

To install the packaged `.vsix` in VS Code or Antigravity:
1. Open the Extensions view (`Ctrl+Shift+X`).
2. Click the **`...`** menu → **Install from VSIX...** and select `tealkit-vscode-0.1.0.vsix`.
