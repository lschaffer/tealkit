# 🛠️ TealKit CLI (`tealkit_cli`)

A native Dart command-line tool for **TealKit** that unifies remote server management, automated configuration discovery, task execution, and **direct local/headless execution of AgentSkills (`SKILL.md`)** powered by [`dart_mcp_core`](https://pub.dev/packages/dart_mcp_core).

---

## 🌟 Features

| Capability | Description |
|---|---|
| 🌐 **Server Management** | Switch between dev/prod server profiles in `server.yaml` and ping health status. |
| 🔍 **Auto-Discovery** | Pull remote LLM settings, task definitions, MCP registry, and skills down to local YAML / Markdown files. |
| 🚀 **Remote Workflow Runner** | Trigger asynchronous workflows/agents, poll execution status, stream execution logs, and download generated artifacts. |
| 🧠 **Direct Skill Execution** | Parse any `SKILL.md` (agentskills.io format), spin up local MCP subprocess tools, and execute prompt sequences end-to-end with live streaming feedback. |
| ⚡ **Ad-Hoc Prompt Runner** | Run single-turn prompts with local LLM and MCP tool calling via CLI or piped `stdin`. |
| 💬 **Interactive Agent REPL** | Multi-turn terminal chat with tool call cards, dynamic model switching (`/llm`), session saving/resuming (`.json`/`.md`), MCP uninstallation (`/uninstall`), token cost estimation (`/estimated_costs`), and slash commands. |
| 💻 **Coding Agent REPL (`tealkit code`)** | Claude Code / Roo Code style terminal coding agent with Architect, Code, and Ask modes, 10 native tools (`fs_find`, `fs_list_dir`, `fs_read_file`, `fs_write_file`, `fs_replace_text`, `fs_create_dir`, `fs_move`, `fs_delete`, `terminal_exec`, `fetch_web`), session persistence, token cost tracking, `tasks.md` checklists, and `tealkit_agent.md` workspace rules. |

---

## 📦 Installation & Setup

### Prerequisites
- [Dart SDK](https://dart.dev/get-dart) >= 3.8.0 (included with Flutter)
- Optional: Node.js (`npx`) or Python (`uvx` / `pip`) for local MCP tools.

### 1. Install Dependencies
```bash
cd cli
dart pub get
```

### 2. Run via Dart
```bash
dart run bin/tealkit.dart --help
```

### 3. Compile Native Standalone Executable
You can compile the CLI into a standalone native binary for instant startup:
```bash
# Windows
dart compile exe bin/tealkit.dart -o tealkit.exe

# Linux / macOS
dart compile exe bin/tealkit.dart -o tealkit
chmod +x tealkit
```

---

## ⚙️ Configuration & Global Fallbacks

TealKit resolves configuration files (`server.yaml`, `llm.yaml`, `extern_mcp_tools.yaml`, `mcp.yaml`, `skills/`, `permissions.yaml`) in the following priority order:
1. **Local Directory**: First checks `./<file>` in current working directory.
2. **Global Fallback Directory**: If not found locally, checks user's home directory (`~/.tealkit/` on Linux/macOS or `%USERPROFILE%\.tealkit` on Windows).
3. **Environment Variables**: Reads `.env` / system environment variables for API keys and endpoint substitutions.

### `server.yaml` (Server Profiles)
Manage one or more TealKit server endpoints:
```yaml
servers:
  - name: "Local Dev"
    url: "http://localhost:7771"
    api_key: ""
    is_active: true

  - name: "Production Server"
    url: "https://agent.yourdomain.com"
    api_key: "${TEALKIT_API_KEY}"
    is_active: false
```
*(Environment variables like `${TEALKIT_API_KEY}` are automatically resolved from `.env` or system environment).*

### `llm.yaml` (Multi-LLM Configuration Array)
Define one or more LLM providers with a default fallback or named model profiles:
```yaml
# Global defaults inherited by all models unless overridden
temperature: 0.1
max_tokens: 8192
max_tool_iterations: 100

# Multi-model array
models:
  - name: "deepseek"
    provider: "openai_compatible"
    model: "deepseek-ai/DeepSeek-V3"
    api_key: "${DEEPSEEK_API_KEY}"
    base_url: "https://api.deepinfra.com/v1/openai"

  - name: "mistral"
    provider: "mistral"
    model: "mistral-medium-latest"
    api_key: "${MISTRAL_API_KEY}"
    base_url: "https://api.mistral.ai/v1"

  - name: "openai"
    provider: "openai"
    model: "gpt-4o-mini"
    api_key: "${OPENAI_API_KEY}"

  - name: "ollama"
    provider: "ollama"
    model: "qwen2.5-coder:7b"
    base_url: "http://localhost:11434"
```
*(Single model format with top-level `provider` & `model` is also backward-compatible).*

### `extern_mcp_tools.yaml` (External MCP Tool Servers)
Define stdio subprocess tools:
```yaml
servers:
  - id: "filesystem"
    name: "Filesystem MCP"
    is_local: true
    local_type: "nodejs"
    local_install_method: "npx"
    custom_launch_command: "npx -y @modelcontextprotocol/server-filesystem ."
    enabled: true
```

---

## 💡 Practical Examples

### 1. Server Profile Management & Health Check
```bash
# List all configured server profiles
tealkit server list

# Switch active server to profile #2 (or by name)
tealkit server activate 2
tealkit server activate "Local Dev"

# Verify connectivity & latency
tealkit ping
```

### 2. Configuration Auto-Discovery
Download active configuration directly from your remote TealKit server into local files:
```bash
# Auto-discover all configs in one step
tealkit auto-discover all

# Or discover selectively:
tealkit auto-discover llm       # writes llm.yaml
tealkit auto-discover workflows # writes workflows.yaml & agents.yaml (alias: agents)
tealkit auto-discover mcp       # writes mcp.yaml
tealkit auto-discover skills    # downloads skills into ./skills/*.md
```

### 3. Remote Workflow Management
Trigger and monitor workflows (tasks/agents) running on your TealKit server by name (with spaces or underscores) or UUID:
```bash
# List all workflows
tealkit workflow list

# Trigger execution of a workflow by name or UUID (names with spaces work with or without quotes)
tealkit workflow run "latest news"
tealkit workflow run latest_news
tealkit workflow run latest news
tealkit workflow run 7f2aa88a-bdff-435e-9cb8-1c68b7353d9f

# Check current run status
tealkit workflow status "latest news"

# View execution logs
tealkit workflow logs "latest news"

# Download generated output file (supports workflow names with spaces)
tealkit workflow download "latest news" report.json
```
*(Note: `tealkit agent` and `tealkit task` are fully supported as backward-compatible aliases for `tealkit workflow`.)*

### 4. Direct Execution of Prompts from an AgentSkill (`SKILL.md`)
Directly execute prompt workflows defined in `SKILL.md` files without a server, utilizing local LLMs and MCP tools:
```bash
# List all local skills found in ./skills/
tealkit skill list

# Inspect skill frontmatter, steps, and required tools
tealkit skill info skills/device_audit.md

# Preview execution without making LLM calls
tealkit skill run skills/device_audit.md --dry-run

# Execute all prompt steps sequentially with live tool streaming
tealkit skill run skills/device_audit.md

# Execute only step #2
tealkit skill run skills/device_audit.md --step 2

# Pass custom parameters into prompt templates (e.g. ${city})
tealkit skill run skills/weather_plan.md -p city=Tokyo -p days=3
```

### 5. Ad-Hoc Prompt Execution with Tool Access
Execute one-off prompts with local LLM and connected MCP tools.

> 💡 **Prerequisite Note on Tools**: Depending on what your prompt needs to do (e.g. reading directories, inspecting files, searching the web, or querying databases), an external local stdio or remote HTTP MCP tool is required.
> - Tools should be configured in `mcp.yaml` (or `extern_mcp_tools.yaml`), or auto-discovered directly from your TealKit server using `tealkit auto-discover mcp`.
> - For example, the directory listing prompt below requires the local filesystem tool (`@modelcontextprotocol/server-filesystem`). If no tool is configured or enabled in `mcp.yaml`, the LLM will reply using only its internal training data without actual filesystem access.

```bash
# Run a one-off prompt (requires filesystem tool configured in mcp.yaml)
tealkit prompt run "List files in the current directory and summarize markdown files"

# Run with a custom system prompt
tealkit prompt run "Fetch https://news.ycombinator.com and extract top 3 stories" --system "You are a concise tech curator"

# Pipe input from another command or file
cat query.txt | tealkit prompt run
```

### 6. Interactive Multi-Turn Agent Chat REPL
Start a live terminal session with access to your configured MCP tools:
```bash
# Standard interactive chat
tealkit chat

# Interactive chat pre-loaded with an AgentSkill's system prompt and tools
tealkit chat --skill skills/device_audit.md
```

**In-chat slash commands:**
- `/llm` or `/llm:<name>` — List models or switch active model profile on the fly (e.g. `/llm:deepseek`, `/llm:mistral`)
- `/uninstall <name>` or `/uninstall all_mcp` — Disconnect external MCP server and purge its local package cache (`uv`/`npm`)
- `/save-session <file.json|.md>` — Save current conversation transcript and turn history
- `/load-session <file.json|.md>` — Restore and resume a previous conversation session
- `/estimated_costs` or `/costs` — View token usage summary and estimated session costs
- `/session` — Display active model, turn count, and token metrics
- `/tools` — View connected MCP tools
- `/system` — View current system prompt
- `/clear` or `/clear-session` — Reset conversation history and token metrics
- `/exit` or `/bye` — Quit session

---

### 7. Autonomous Coding Agent REPL (`tealkit code`)
Run a terminal coding agent (Claude Code / Roo Code style) capable of autonomous codebase exploration, planning via `tasks.md`, and surgical code editing with build/test verification.

```bash
# Start coding agent in current repository
tealkit code

# Start with a specific named LLM model profile from llm.yaml
tealkit code --llm:deepseek
tealkit code --llm mistral

# Start in Architect (Planning) mode
tealkit code --mode architect

# Load custom workspace instructions
tealkit code --instructions tealkit_agent.md

# Resume a previous coding session from JSON or Markdown
tealkit code --load-session ./coding-session.json

# Automatically save session upon exit
tealkit code --save-session ./coding-session.md

# Configure tool iteration exploration limit (defaults to 100)
tealkit code --max-tool-iterations 150

# Load custom external MCP servers configuration
tealkit code --tools mcp.yaml
```

> 💡 **Unified Tooling**: The coding agent automatically merges the **10 Native Pure-Dart Tools** with any **External MCP Servers** (e.g. GitHub, Postgres, Memory MCP) defined in `mcp.yaml` or `extern_mcp_tools.yaml`.

#### 🔄 Operational Modes
- **📐 ARCHITECT (`/plan` or `/mode architect`)**: Explores the codebase, analyzes dependencies, and creates or updates `tasks.md` checklists without touching production code.
- **💻 CODE (`/code` or `/mode code`)**: Follows `tasks.md`, executes minimal surgical edits (`fs_replace_text`), runs terminal build/test checks (`terminal_exec`), and checks off items (`- [x]`).
- **💬 ASK (`/ask` or `/mode ask`)**: Read-only Q&A and codebase exploration.

#### 🧰 Native Pure-Dart Tools (Powered by `dart_mcp_core`)
- `fs_find`: Fast directory and file search matching wildcard patterns (e.g. `src/*.cs`, `*.csproj`) with `.gitignore` filtering.
- `fs_list_dir`: Structured directory inspection with file sizes and type tags (`[DIR]`, `[FILE]`).
- `fs_read_file`: Line-numbered, paginated file viewing (capped to 800 lines max per read to safeguard LLM context windows).
- `fs_write_file`: File creation and full overwrite with automatic parent directory generation.
- `fs_replace_text`: Exact, unique search-and-replace block edits (ideal for small/open models).
- `fs_create_dir`: Create directory hierarchy (`src/Core/Models`) recursively.
- `fs_move`: Rename or move files and directories.
- `fs_delete`: Delete files or directories (supports recursive folder deletion).
- `terminal_exec`: Execution of workspace commands (`dotnet build`, `dart test`, `git status`) with output capture.
- `fetch_web`: Direct HTTP GET tool for querying web pages, pub.dev API, NuGet, and docs without external proxies.

#### ⚡ In-Session Slash Commands
- `/plan`, `/code`, `/ask` — Quickly switch operational modes.
- `/llm` or `/llm:<name>` — List configured models or switch active LLM profile immediately (e.g. `/llm:deepseek`, `/llm:mistral`, `/llm:openai`).
- `/uninstall <id>` or `/uninstall all_mcp` — Disconnect MCP servers and purge cached packages (`uv cache clean` / `npm cache clean --force`).
- `/save-session <path.json|.md>` — Export current conversation history and task state.
- `/load-session <path.json|.md>` — Import previous conversation and continue work seamlessly.
- `/estimated_costs` or `/costs` — View prompt, completion, total token usage and estimated USD costs.
- `/session` — Display active model, turn count, and token usage summary.
- `/permissions` — Inspect current tool approval requirements (read, write, execute, network).
- `/auto-approve <on|off>` — Toggle auto-approval on the fly for writes and terminal executions.
- `/tasks` — Display the current contents of `tasks.md`.
- `/instructions` — View or reload instructions from `tealkit_agent.md`.
- `/tools` — List active coding tools.
- `/clear` or `/clear-session` — Reset conversation turn history and token cost statistics.
- `/exit` — Quit coding session.

#### 🛡️ Human-in-the-Loop Permissions
Whenever the agent attempts to modify a file (`fs_write_file`, `fs_replace_text`) or run a shell command (`terminal_exec`), the CLI prompts for confirmation:
```text
⚠️  Tool Approval Requested:
  • Tool   : fs_replace_text (ToolRiskLevel.write)
  • Args   : {"path":"src/MyApp.csproj","search":"<TargetFramework>net8.0","replace":"<TargetFramework>net9.0"}
Approve execution? [y/n/always/deny-all] >
```
- Type `y` or Enter: Approve the single tool call.
- Type `n`: Deny the tool call (the agent receives a rejection message and adjusts its plan).
- Type `always` or `a`: Auto-approve all future actions for this category and persist to `~/.tealkit/permissions.yaml`.
- Type `deny-all` or `d`: Block and disable auto-approvals.

---

## 📋 Command Reference

```text
TealKit CLI — Server orchestration, auto-discovery, and direct AgentSkill execution.

Usage: tealkit <command> [arguments]

Available commands:
  server          Manage TealKit server connection profiles.
    list          List all configured server profiles.
    activate      Activate a profile by name or 1-based index.
  ping            Verify connectivity and health with the active TealKit server.
  auto-discover   Auto-discover configurations from active server.
    llm           Download server LLM settings to llm.yaml.
    workflows     Download remote workflows/agents to workflows.yaml (aliases: agents, tasks).
    mcp           Download MCP server registry to mcp.yaml.
    skills        Download skills into ./skills/*.md.
    all           Execute all auto-discoveries in sequence.
  workflow        Manage and execute remote workflows and tasks on the server (aliases: agent, task).
    list          List workflows on the server.
    run           Trigger workflow execution on the server (by name or ID).
    status        Check running status and latest output.
    cancel        Cancel a running workflow on the server.
    logs          Fetch execution logs for a workflow.
    download      Download an output file for a workflow run.
  skill           Inspect and execute AgentSkills (SKILL.md) workflows.
    list          List local or remote (--remote) skills.
    info          Inspect skill frontmatter and prompt sequence.
    run           Directly execute prompt steps from a skill file.
  prompt          Execute an ad-hoc prompt with local LLM and MCP tools.
    run           Run prompt with optional --system prompt or piped stdin.
  chat            Start an interactive multi-turn terminal agent session.
  code            Launch interactive coding agent REPL (Claude Code / Roo Code style).
```
