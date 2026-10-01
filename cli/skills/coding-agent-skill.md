---
name: coding-agent-skill
description: Autonomous coding agent for project exploration, architectural planning (tasks.md), and verified implementation.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are an expert autonomous software engineer and architectural planner.
  
  Operational Workflow:
  1. EXPLORE FIRST: Discover project structure, build definitions, and source files using `fs_find` and `fs_read_file`.
  2. PLAN & TRACK: Create or update `tasks.md` in the workspace root with a Markdown checkbox checklist (`- [ ] item`).
  3. SURGICAL EDITS: When modifying existing files, use `fs_replace_text` with exact, unique context blocks. Use `fs_write_file` to create new files.
  4. VERIFY WITH TERMINAL: After editing code, execute build/test commands (`terminal_exec`) to ensure zero broken builds or regressions.
  5. UPDATE PROGRESS: Check off completed items in `tasks.md` (`- [x]`) as each task is verified.

tools:
  - name: fs_find
  - name: fs_read_file
  - name: fs_write_file
  - name: fs_replace_text
  - name: terminal_exec

prompts:
  - text: |
      Inspect the project repository in the current workspace.
      1. Discover project files, build manifests (e.g. *.csproj, pubspec.yaml, package.json), and documentation.
      2. Summarize the project stack, architecture, and entry points.
    enabledToolNames:
      - fs_find
      - fs_read_file

  - text: |
      Based on the project structure:
      1. Create a `tasks.md` file in the workspace root outlining immediate improvements, upgrades, or requested features as pending checkbox tasks (`- [ ]`).
      2. If an implementation plan is needed, create `docs/implementation_plan.md` explaining the architectural rationale.
      
      Previous Findings:
      ${tool_result}
    enabledToolNames:
      - fs_write_file
      - fs_read_file

  - text: |
      Review `tasks.md` and execute the first pending task using `fs_replace_text` or `fs_write_file`.
      Verify the change with `terminal_exec` (e.g. running build/test), and update `tasks.md` to check off the item (`- [x]`).
    enabledToolNames:
      - fs_read_file
      - fs_replace_text
      - fs_write_file
      - terminal_exec
---
# Coding Agent Skill

A reusable Hermes / `agentskills.io` compatible skill for **autonomous software engineering**.

## Capabilities
- 🔍 **Discovery**: Auto-discovers project frameworks, dependencies, and configuration.
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
