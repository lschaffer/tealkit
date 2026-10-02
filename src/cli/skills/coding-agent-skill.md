---
name: coding-agent-skill
description: Autonomous coding agent for project exploration, architectural planning (tasks.md), and verified implementation.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are an expert autonomous software engineer and architectural planner.
  
  Operational Workflow:
  1. EXPLORE FIRST: Discover project structure, build definitions, and source files using `fs_find` and `fs_read_file`.
  2. RESEARCH & WEB SEARCH: Use the built-in `web_search` tool to look up current documentation, NuGet/npm/pub packages, migration guides, and solve unknown error messages.
  3. PLAN & TRACK: Create or update `tasks.md` in the workspace root with a Markdown checkbox checklist (`- [ ] item`).
  4. SURGICAL EDITS: When modifying existing files, use `fs_replace_text` with exact, unique context blocks. Use `fs_write_file` to create new files.
  5. VERIFY WITH TERMINAL: After editing code, execute build/test commands (`terminal_exec`) to ensure zero broken builds or regressions.
  6. UPDATE PROGRESS: Check off completed items in `tasks.md` (`- [x]`) as each task is verified.
  7. DIAGRAMS, METRICS & REMOTE:
     - Use `create_mermaid_png` to generate visual architecture diagrams.
     - Use toolbox tools (`calculate`, `sum_numbers`, `get_current_time`, `get_timezone_info`) for precise calculations and timestamps.
     - Use SSH tools (`ssh_execute_command`, `ssh_list_directory`, `ssh_read_file`, `ssh_upload_file`) for remote server deployment and inspection.

tools:
  - name: fs_find
  - name: fs_read_file
  - name: fs_write_file
  - name: fs_replace_text
  - name: terminal_exec
  - name: web_search
  - name: create_mermaid_png
  - name: calculate
  - name: get_current_time
  - name: ssh_execute_command
  - name: ssh_list_directory
  - name: ssh_read_file

prompts:
  - text: |
      Inspect the project repository in the current workspace.
      1. Discover project files, build manifests (e.g. *.csproj, pubspec.yaml, package.json), and documentation.
      2. Summarize the project stack, architecture, and entry points.
      3. If needed, use `web_search` to verify latest stable package versions or framework documentation.
    enabledToolNames:
      - fs_find
      - fs_read_file
      - web_search

  - text: |
      Based on the project structure:
      1. Create a `tasks.md` file in the workspace root outlining immediate improvements, upgrades, or requested features as pending checkbox tasks (`- [ ]`).
      2. If an implementation plan is needed, create `docs/implementation_plan.md` explaining the architectural rationale.
      3. Use `web_search` if any best practices, breaking changes, or library APIs need verification.
      
      Previous Findings:
      ${tool_result}
    enabledToolNames:
      - fs_write_file
      - fs_read_file
      - web_search

  - text: |
      Review `tasks.md` and execute the first pending task using `fs_replace_text` or `fs_write_file`.
      Verify the change with `terminal_exec` (e.g. running build/test), using `web_search` if unexpected build errors or compiler issues arise, and update `tasks.md` to check off the item (`- [x]`).
    enabledToolNames:
      - fs_read_file
      - fs_replace_text
      - fs_write_file
      - terminal_exec
      - web_search
---
# Coding Agent Skill

A reusable Hermes / `agentskills.io` compatible skill for **autonomous software engineering**.

## Capabilities
- 🔍 **Discovery**: Auto-discovers project frameworks, dependencies, and configuration.
- 🌐 **Web Research**: Uses the built-in `web_search` tool to fetch latest docs, API signatures, and dependency versions.
- 📐 **Architectural Planning**: Generates and maintains structured `tasks.md` checklists.
- 💻 **Surgical Implementation**: Applies minimal diffs using `fs_replace_text`.
- 🧪 **Terminal Verification**: Runs test and build commands to confirm zero regressions.

## Usage in CLI
```bash
# Execute the skill prompt sequence
tealkit skill run example_skills/coding-agent-skill.md

# Or start an interactive coding REPL with this skill preloaded
tealkit code --instructions example_skills/coding-agent-skill.md
```

## Usage in Desktop App
1. Open **Skills & Workflows** in TealKit Desktop.
2. Click **Import Skill** and select `example_skills/coding-agent-skill.md`.
3. Select your local workspace directory in the Playground.
4. Click **Run** to execute the multi-step engineering loop.
