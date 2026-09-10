# 🛠️ TealKit CLI (`tealkit_cli`)

A native Dart command-line tool for **TealKit** that unifies remote server management, automated configuration discovery, task execution, and **direct local/headless execution of AgentSkills (`SKILL.md`)** powered by [`mcp_playground_dart`](https://pub.dev/packages/mcp_playground_dart).

---

## 🌟 Features

| Capability | Description |
|---|---|
| 🌐 **Server Management** | Switch between dev/prod server profiles in `server.yaml` and ping health status. |
| 🔍 **Auto-Discovery** | Pull remote LLM settings, task definitions, MCP registry, and skills down to local YAML / Markdown files. |
| 🚀 **Remote Workflow Runner** | Trigger asynchronous workflows/agents, poll execution status, stream execution logs, and download generated artifacts. |
| 🧠 **Direct Skill Execution** | Parse any `SKILL.md` (agentskills.io format), spin up local MCP subprocess tools, and execute prompt sequences end-to-end with live streaming feedback. |
| ⚡ **Ad-Hoc Prompt Runner** | Run single-turn prompts with local LLM and MCP tool calling via CLI or piped `stdin`. |
| 💬 **Interactive Agent REPL** | Multi-turn terminal chat with tool call cards, parameter introspection, and slash commands (`/tools`, `/system`, `/clear`, `/exit`). |

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

## ⚙️ Configuration

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

### `llm.yaml` (Local LLM Configuration)
Used for direct skill and prompt execution:
```yaml
provider: "openai"                  # openai | claude | gemini | ollama | mistral | openai_compatible
model: "gpt-4o-mini"
api_key: "${OPENAI_API_KEY}"
base_url: ""
temperature: 0.2
max_tokens: 4096
```

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
- `/tools` — View connected MCP tools
- `/system` — View current system prompt
- `/clear` — Reset conversation history
- `/exit` or `/bye` — Quit session

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
```
