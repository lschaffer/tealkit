# TealKit CLI (`tealkit_cli`) Development TODO

This is the development plan for the upcoming TealKit command-line tool. The CLI will be a native Dart console application running under the monorepo structure.

## Milestone 1: Scaffold and Configuration Profile

- [ ] Create Dart CLI console project:
  ```bash
  cd cli
  dart create -t console ./
  ```
- [ ] Configure `pubspec.yaml` with the dependencies:
  - `tealkit_api` (local path: `../api`)
  - `args` (for CLI parameter parsing)
  - `yaml` (for parsing local profile files)
- [ ] Implement `server.yaml` parser to load connection profiles:
  ```yaml
  servers:
    - name: "Local Dev"
      url: "http://localhost:7771"
      api_key: "tk-key-abc"
      is_active: true
  ```
- [ ] Create commands:
  - `tealkit server list`
  - `tealkit server activate <index>`
  - `tealkit ping` (verifies connection via `/health`)

## Milestone 2: Configuration Auto-Discovery

- [ ] Auto-discover LLM configurations:
  - Call `GET /api/v1/settings/llm`
  - Save to local `llm.yaml`
  - Command: `tealkit auto-discover llm`
- [ ] Auto-discover Agent/Task configurations:
  - Call `GET /api/v1/tasks`
  - Save to local `agents.yaml`
  - Command: `tealkit auto-discover agents`
- [ ] Auto-discover MCP Registry settings:
  - Call `GET /api/v1/mcp/registry`
  - Save to local `mcp.yaml`
  - Command: `tealkit auto-discover mcp`
- [ ] Discover all configuration settings:
  - Command: `tealkit auto-discover all`

## Milestone 3: Task Management and Execution

- [ ] List tasks (`tealkit agent list`)
- [ ] Trigger task run (`tealkit agent run <task-id>`)
- [ ] Check task run status (`tealkit agent status <task-id>`)
- [ ] Cancel executing tasks (`tealkit agent cancel <task-id>`)
- [ ] Download run outputs and logs (`tealkit agent logs <task-id>` & `tealkit agent download <task-id> <filename>`)

## Milestone 4: Compilation and Multi-Platform Packaging

- [ ] Add native compilation script using `dart compile exe bin/tealkit.dart -o tealkit.exe`
- [ ] Set up CI/CD pipeline inside GitHub Actions for multi-platform binaries (Windows, macOS, Linux).
