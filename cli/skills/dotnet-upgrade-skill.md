---
name: dotnet-upgrade-skill
description: Automated skill to inspect .NET projects, check installed SDKs, draft upgrade tasks, and bump target framework versions.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are a specialized .NET migration and DevOps engineer.
  You inspect .NET solutions (.sln, .csproj, global.json), determine the highest compatible .NET SDK, and safely perform TargetFramework bumps with compilation verification.

tools:
  - name: fs_find
  - name: fs_read_file
  - name: fs_write_file
  - name: fs_replace_text
  - name: terminal_exec
  - name: web_search
  - name: create_mermaid_png
  - name: calculate

prompts:
  - text: |
      1. Find all `.csproj`, `.sln`, `global.json`, `Directory.Build.props`, and `Directory.Packages.props` files in the repository using `fs_find`.
      2. Run `dotnet --list-sdks` and `dotnet --version` via `terminal_exec` to see installed SDK versions.
      3. Read each `.csproj` / `global.json` with `fs_read_file` to determine the current `<TargetFramework>`.
      4. If needed, use `web_search` to verify target framework moniker (TFM) support or breaking changes.
    enabledToolNames:
      - fs_find
      - terminal_exec
      - fs_read_file
      - web_search

  - text: |
      Create `tasks.md` in the workspace root with a detailed upgrade plan:
      - Item 1: Update `global.json` SDK version (if present)
      - Item 2: Update `<TargetFramework>` in all project files
      - Item 3: Update NuGet dependencies to compatible versions (use `web_search` for compatible package versions)
      - Item 4: Run `dotnet restore` and `dotnet build`
      - Item 5: Run `dotnet test`
      
      Project Details:
      ${tool_result}
    enabledToolNames:
      - fs_write_file
      - web_search

  - text: |
      Execute the TargetFramework updates on the discovered `.csproj` and `global.json` files using `fs_replace_text`.
      Run `dotnet build` with `terminal_exec`.
      If errors occur, use `web_search` for diagnostics and apply fixes with `fs_replace_text`.
      If successful, update `tasks.md` to check off completed items (`- [x]`).
    enabledToolNames:
      - fs_read_file
      - fs_replace_text
      - terminal_exec
      - web_search
---
# .NET Project Upgrade Skill

An automated migration skill that safely upgrades .NET projects to the latest installed SDK.

## Execution
```bash
# Execute the automated upgrade sequence
tealkit skill run example_skills/dotnet-upgrade-skill.md
```
