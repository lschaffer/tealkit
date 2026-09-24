# TealKit CLI (`tealkit_cli`) Development TODO

This is the development plan for the upcoming TealKit command-line tool. The CLI is a native Dart console application running under the monorepo structure, supporting both remote TealKit server management and local headless execution of AgentSkills (`SKILL.md`) powered by `dart_mcp_core`.

## Milestone 1: Scaffold and Configuration Profile

- [x] Create Dart CLI console project:
  ```bash
  cd cli
  dart create -t console ./
  ```
- [x] Configure `pubspec.yaml` with dependencies:
  - `tealkit_api` (local path: `../api`)
  - `dart_mcp_core` (pub.dev)
  - `args` (for CLI parameter and subcommand parsing)
  - `yaml` (for parsing local profile and config files)
  - `http` & `path`
- [x] Implement `server.yaml` parser to load and persist connection profiles:
  ```yaml
  servers:
    - name: "Local Dev"
      url: "http://localhost:7771"
      api_key: "tk-key-abc"
      is_active: true
  ```
- [x] Create server commands:
  - `tealkit server list`
  - `tealkit server activate <name|index>`
  - `tealkit ping` (verifies connection via `/health`)

## Milestone 2: Configuration Auto-Discovery

- [x] Auto-discover LLM configurations:
  - Call `GET /api/v1/settings/llm`
  - Save to local `llm.yaml` (with `${ENV_VAR}` template support)
  - Command: `tealkit auto-discover llm`
- [x] Auto-discover Agent/Task configurations:
  - Call `GET /api/v1/tasks`
  - Save to local `agents.yaml`
  - Command: `tealkit auto-discover agents`
- [x] Auto-discover MCP Registry settings:
  - Call `GET /api/v1/mcp/registry`
  - Save to local `mcp.yaml` / `extern_mcp_tools.yaml`
  - Command: `tealkit auto-discover mcp`
- [x] Auto-discover Skills:
  - Call `GET /api/v1/skill-defs`
  - Save skills locally into `skills/<skill_name>.md`
  - Command: `tealkit auto-discover skills`
- [x] Discover all configuration settings:
  - Command: `tealkit auto-discover all`

## Milestone 3: Remote Workflow Management and Execution

- [x] List workflows (`tealkit workflow list` / aliases: `agent`, `task`)
- [x] Trigger workflow run by name or UUID, supporting spaces (`tealkit workflow run <workflow-name-or-id>`)
- [x] Check workflow run status (`tealkit workflow status <workflow-name-or-id>`)
- [x] Cancel executing workflows (`tealkit workflow cancel <workflow-name-or-id>`)
- [x] Download run outputs and logs (`tealkit workflow logs <workflow-name-or-id>` & `tealkit workflow download <workflow-name-or-id> <filename>`)

## Milestone 4: Direct Skill & Prompt Execution Engine (via `dart_mcp_core`)

- [x] Integrate `SkillImporter` from `dart_mcp_core`:
  - Parse agentskills.io and TealKit `SKILL.md` manifests.
  - Extract `system_prompt`, `prompts` sequence (`promptSteps`), and required `tools` (MCP servers).
- [x] Implement `tealkit skill` commands:
  - `tealkit skill list`: List skills found in `./skills` or server.
  - `tealkit skill info <path-to-skill.md>`: Inspect frontmatter, prompt steps, and tool requirements.
  - `tealkit skill run <path-to-skill.md>`:
    - Load LLM configuration (`llm.yaml` or `.env`).
    - Connect needed MCP servers via `MultiMCPManager` / `LocalMCPClient`.
    - Sequentially execute prompt steps using `McpAgentEngine`.
    - Stream tool invocations, inputs, results, and assistant response chunks to stdout.
    - Support `--step <index>` to run individual steps.
    - Support `--param <key=value>` / `-D <key=value>` variable interpolation in prompt templates.
    - Support `--dry-run` to preview execution flow without calling LLMs.
- [x] Implement ad-hoc prompt execution:
  - `tealkit prompt run "<prompt>"` (or `tealkit run -p "<prompt>"`): One-shot prompt execution with connected MCP tools.
  - Support piped input (`cat data.txt | tealkit prompt run "Summarize"`).
- [x] Implement interactive REPL:
  - `tealkit chat [--skill <path>]`: Terminal chat session supporting multi-turn conversations, live tool execution, and slash commands (`/tools`, `/system`, `/clear`, `/exit`).

## Milestone 5: Compilation and Multi-Platform Packaging

- [x] Add native compilation script using `dart compile exe bin/tealkit.dart -o tealkit.exe`
- [ ] Set up CI/CD pipeline inside GitHub Actions for multi-platform binaries (Windows, macOS, Linux).
