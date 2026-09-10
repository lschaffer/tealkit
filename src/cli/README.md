# 🛠️ TealKit CLI (`tealkit_cli`)

A native Dart command-line tool for **TealKit** that unifies remote server management, automated configuration discovery, task execution, and **direct local/headless execution of AgentSkills (`SKILL.md`)** powered by [`mcp_playground_dart`](https://pub.dev/packages/mcp_playground_dart).

---

## 🌟 Features

| Capability | Description |
|---|---|
| 🌐 **Server Management** | Switch between dev/prod server profiles in `server.yaml` and ping health status. |
| 🔍 **Auto-Discovery** | Pull remote LLM settings, task definitions, MCP registry, and skills down to local YAML / Markdown files. |
| 🚀 **Remote Task Runner** | Trigger asynchronous tasks, poll execution status, stream execution logs, and download generated artifacts. |
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
tealkit auto-discover agents    # writes agents.yaml
tealkit auto-discover mcp       # writes mcp.yaml
tealkit auto-discover skills    # downloads skills into ./skills/*.md
```

### 3. Remote Task Management
Trigger and monitor tasks running on your TealKit server:
```bash
# List all tasks
tealkit agent list

# Trigger execution of a task
tealkit agent run task_daily_briefing

# Check current run status
tealkit agent status task_daily_briefing

# View execution logs
tealkit agent logs task_daily_briefing

# Download generated output file
tealkit agent download task_daily_briefing report.json
```

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
```bash
# Run a one-off prompt
tealkit prompt run "List files in the current directory and summarize markdown files"

# Pipe input from another command
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
    agents        Download remote tasks/agents to agents.yaml.
    mcp           Download MCP server registry to mcp.yaml.
    skills        Download skills into ./skills/*.md.
    all           Execute all auto-discoveries in sequence.
  agent           Manage and execute remote tasks on the server (alias: task).
    list          List tasks on the server.
    run           Trigger task execution on the server.
    status        Check running status and latest output.
    cancel        Cancel a running task on the server.
    logs          Fetch execution logs for a task.
    download      Download an output file for a task run.
  skill           Inspect and execute AgentSkills (SKILL.md) workflows.
    list          List local or remote (--remote) skills.
    info          Inspect skill frontmatter and prompt sequence.
    run           Directly execute prompt steps from a skill file.
  prompt          Execute an ad-hoc prompt with local LLM and MCP tools.
    run           Run prompt with optional --system prompt or piped stdin.
  chat            Start an interactive multi-turn terminal agent session.
```
