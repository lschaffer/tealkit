# Implementation Plan - TealKit CLI (`tealkit_cli`) with Direct Skill & Prompt Execution

Build the native Dart command-line tool `tealkit_cli` under `cli/`, implementing server configuration, auto-discovery, remote task management, and extending the capability with direct local/headless execution of prompts from AgentSkills (`SKILL.md`) using `dart_mcp_core`.

## Background & Architecture

The existing [cli/todo.md](file:///c:/projects/ls/mobile_ai_agent/cli/todo.md) outlines milestones for a client tool interacting with the TealKit server (`tealkit_api`). The user requested to **extend the TODO and architecture** to allow **direct execution of prompts from skills**, powered by `dart_mcp_core`:

1. **TealKit Remote Server Orchestration** (via `tealkit_api`):
   - Manage servers via `server.yaml` profiles (`server list`, `server activate`, `ping`).
   - Auto-discover remote configurations into local YAML files (`llm.yaml`, `agents.yaml`, `mcp.yaml`, and `skills/`).
   - Remote agent/task lifecycle (`agent list`, `run`, `status`, `cancel`, `logs`, `download`).
2. **Direct Local Skill & Prompt Execution Engine** (via `dart_mcp_core`):
   - Parse `SKILL.md` (agentskills.io and TealKit formats) using `SkillImporter`.
   - Resolve local/external MCP tool definitions (`extern_mcp_tools.yaml` / `mcp.yaml`) and connect stdio/HTTP MCP servers using `LocalMCPClient` & `MultiMCPManager`.
   - Sequentially execute prompt steps defined in the skill using `McpAgentEngine`.
   - Real-time terminal streaming of tool calls, arguments, outputs, and assistant tokens with ANSI/box-drawing formatting.
   - Interactive REPL (`tealkit chat [--skill <path>]`) for multi-turn agent interaction.

```
┌─────────────────────────────────────────────────────────────┐
│                    TealKit CLI (tealkit)                    │
├──────────────────────────────┬──────────────────────────────┤
│    Server Mode (Remote)      │    Skill / Engine Mode       │
│      (tealkit_api)           │    (dart_mcp_core)           │
├──────────────────────────────┼──────────────────────────────┤
│ • server list/activate/ping  │ • skill run <path.md>        │
│ • auto-discover llm/mcp/task │ • prompt run "<text>"        │
│ • agent run/status/cancel    │ • chat [--skill <path.md>]   │
│ • logs / output download     │ • live tool execution stream │
└──────────────────────────────┴──────────────────────────────┘
```

---

## User Review Required

> [!IMPORTANT]
> **Dependency Source for `dart_mcp_core`**:
> `dart_mcp_core` is published on pub.dev (`^1.0.2`), replacing the deprecated `mcp_playground_dart`.

---

## Proposed Changes

### 1. Updated CLI Development TODO: [cli/todo.md](file:///c:/projects/ls/mobile_ai_agent/cli/todo.md)

We will extend [cli/todo.md](file:///c:/projects/ls/mobile_ai_agent/cli/todo.md) with the new **Skill & Direct Prompt Execution** milestone:
- **Milestone 1**: Scaffold and Configuration Profile (`server.yaml`, `server` commands, `ping`)
- **Milestone 2**: Configuration Auto-Discovery (`auto-discover llm`, `agents`, `mcp`, `skills`, `all`)
- **Milestone 3**: Remote Task Management and Execution (`agent list`, `run`, `status`, `cancel`, `logs`, `download`)
- **Milestone 4 (NEW)**: Direct Skill & Prompt Execution Engine (Powered by `dart_mcp_core`):
  - Parse `SKILL.md` manifests (YAML frontmatter + prompt steps)
  - `tealkit skill list`, `tealkit skill info <file>`
  - `tealkit skill run <path-to-skill.md> [--step <n>] [--param key=val]`
  - `tealkit prompt run "<prompt>"` (single prompt direct execution)
  - `tealkit chat [--skill <path>]` (interactive REPL with MCP tools and streaming feedback)
- **Milestone 5**: Native Compilation & Multi-Platform Packaging (`dart compile exe`)

---

### 2. CLI Project Scaffold & Dependencies: [cli/pubspec.yaml](file:///c:/projects/ls/mobile_ai_agent/cli/pubspec.yaml)

#### [NEW] [cli/pubspec.yaml](file:///c:/projects/ls/mobile_ai_agent/cli/pubspec.yaml)
```yaml
name: tealkit_cli
description: "TealKit native CLI — server management, auto-discovery, task runner, and direct skill prompt execution"
version: 1.0.0
publish_to: 'none'

environment:
  sdk: ^3.8.0

dependencies:
  args: ^2.6.0
  yaml: ^3.1.4
  http: ^1.2.2
  path: ^1.9.0
  tealkit_api:
    path: ../api
  dart_mcp_core: ^1.0.2

dev_dependencies:
  lints: ^6.0.0
  test: ^1.25.0
```

---

### 3. Core CLI Implementation: [cli/lib/](file:///c:/projects/ls/mobile_ai_agent/cli/lib)

#### [NEW] [cli/bin/tealkit.dart](file:///c:/projects/ls/mobile_ai_agent/cli/bin/tealkit.dart)
Main CLI entrypoint using `args/command_runner.dart`:
- Registers `server`, `auto-discover`, `agent`, `skill`, `prompt`, and `chat` commands.
- Handles global flags (`--config`, `--verbose`, `--version`).

#### [NEW] [cli/lib/src/config/server_config.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/config/server_config.dart)
Manages `server.yaml` profiles (loading, selecting, updating active server, creating default `server.yaml` if missing).

#### [NEW] [cli/lib/src/config/env_loader.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/config/env_loader.dart)
Loads `.env` files and performs `${ENV_VAR}` string substitution on YAML files (matching `cli_example`).

#### [NEW] [cli/lib/src/commands/server_command.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/commands/server_command.dart)
- `tealkit server list`: Tabular list of profiles with active indicator `*`.
- `tealkit server activate <name|index>`: Switches active server.
- `tealkit ping`: Runs `ServerApiClient.ping()` and `/health` check with latency timing.

#### [NEW] [cli/lib/src/commands/auto_discover_command.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/commands/auto_discover_command.dart)
- `tealkit auto-discover llm`: Writes `llm.yaml`.
- `tealkit auto-discover agents`: Writes `agents.yaml`.
- `tealkit auto-discover mcp`: Writes `mcp.yaml`.
- `tealkit auto-discover skills`: Fetches `/api/v1/skill-defs` and saves each skill as `<id>.md` in `skills/`.
- `tealkit auto-discover all`: Executes all four discoveries.

#### [NEW] [cli/lib/src/commands/agent_command.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/commands/agent_command.dart)
- `tealkit agent list`: Lists remote tasks.
- `tealkit agent run <task-id>`: Triggers execution, returns `run_id`.
- `tealkit agent status <task-id>`: Checks running state and latest outputs.
- `tealkit agent cancel <task-id>`: Aborts running task.
- `tealkit agent logs <task-id>`: Dumps formatted logs.
- `tealkit agent download <task-id> <filename>`: Downloads output artifacts.

#### [NEW] [cli/lib/src/engine/skill_runner.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/engine/skill_runner.dart)
Core runner integrating `dart_mcp_core`:
- Parses `SKILL.md` using `SkillImporter`.
- Resolves LLM credentials (`llm.yaml`, `.env`, or CLI options).
- Starts subprocess/local MCP servers defined in skill or `mcp.yaml`.
- Connects to `McpAgentEngine`.
- Sequentially executes prompt steps:
  - Subscribes to `engine.agentEvents`.
  - Streams tool invocations (name, args, truncated result box).
  - Streams assistant responses and token chunks.
- Supports template parameter interpolation (`-D key=value`).

#### [NEW] [cli/lib/src/commands/skill_command.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/commands/skill_command.dart)
- `tealkit skill list`: Lists skills in `./skills/` or remote server.
- `tealkit skill info <file>`: Pretty-prints skill manifest (system prompt, prompts, tools).
- `tealkit skill run <path-to-skill.md>`: Executes the skill prompts end-to-end.

#### [NEW] [cli/lib/src/commands/prompt_command.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/commands/prompt_command.dart)
- `tealkit prompt run "<prompt>"`: Quick one-off execution with MCP tools.

#### [NEW] [cli/lib/src/commands/chat_command.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/commands/chat_command.dart)
- `tealkit chat [--skill <path>]`: Interactive REPL agent session with live streaming, slash commands (`/tools`, `/system`, `/clear`, `/exit`).

#### [NEW] [cli/lib/src/formatters/terminal_printer.dart](file:///c:/projects/ls/mobile_ai_agent/cli/lib/src/formatters/terminal_printer.dart)
Clean ANSI colors and box-drawing utilities for tables, headers, and tool call cards.

---

## Verification Plan

### Automated Tests
1. `dart pub get` inside `cli/`:
   ```powershell
   cd cli
   dart pub get
   ```
2. Run unit tests (`test/`):
   - Test `server.yaml` parsing and activation logic.
   - Test `SKILL.md` parsing with `SkillImporter`.
   - Test command runner argument parsing.
   ```powershell
   dart test
   ```

### Functional CLI Verification
1. Verify help output:
   ```powershell
   dart run bin/tealkit.dart --help
   ```
2. Verify `server` commands:
   ```powershell
   dart run bin/tealkit.dart server list
   dart run bin/tealkit.dart ping
   ```
3. Verify `skill info` and `skill run --dry-run`:
   ```powershell
   dart run bin/tealkit.dart skill info ..\examples\flutter\example_device_diagnostics\skill.md
   dart run bin/tealkit.dart skill run ..\examples\flutter\example_device_diagnostics\skill.md --dry-run
   ```
4. Verify executable compilation:
   ```powershell
   dart compile exe bin/tealkit.dart -o tealkit.exe
   .\tealkit.exe --help
   ```
