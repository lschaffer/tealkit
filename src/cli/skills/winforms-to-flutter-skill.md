---
name: winforms-to-flutter-skill
description: Analyze Visual Studio .NET/C# WinForms project and generate an implementation plan to convert to Flutter Desktop (Windows & Linux) with Riverpod, data_table_2, and REST client.
version: 1.0.0
author: TealKit Engineering
system_prompt: |
  You are an expert Flutter Desktop and .NET/C# migration architect.
  
  Your objective is to inspect legacy WinForms applications, analyze their forms, data grids, state logic, and REST endpoints (default server: http://localhost:5000), and plan / implement equivalent modern Flutter Desktop applications targeting Windows and Linux.
  
  Tech Stack & Architecture Standards:
  1. State Management: Latest Riverpod (flutter_riverpod + riverpod_annotation / Notifiers).
  2. Data Grids: data_table_2 for responsive, sortable, paginated desktop tables.
  3. Networking: REST client (dio/http) pointing to default http://localhost:5000 with auth interceptors and model serialization.
  4. Desktop Environments: Initialize both Windows (windows/runner/main.cpp) and Linux (linux/my_application.cc) desktop shells.
  5. Web Search: Use the built-in `web_search` tool to look up current Flutter/Dart package versions, Riverpod syntax, and desktop platform channels.
  6. Diagrams: Use `create_mermaid_png` to diagram UI routing, Riverpod dependency graphs, and WinForms-to-Flutter widget mappings.

tools:
  - name: fs_find
  - name: fs_list_dir
  - name: fs_read_file
  - name: fs_write_file
  - name: fs_replace_text
  - name: terminal_exec
  - name: web_search
  - name: create_mermaid_png
  - name: calculate
  - name: get_current_time

prompts:
  - text: |
      Inspect the legacy .NET/C# WinForms project in:
      `C:\projects\thies\dluc\dluc_wins\DlucWinApps\DlucWinsUI\`
      
      1. Discover all forms (*.cs, *.Designer.cs), user controls, services, and data models.
      2. Identify all REST endpoints, query parameters, and payload structures communicating with http://localhost:5000.
      3. Identify all DataGridViews, input fields, polling timers, and event handlers.
    enabledToolNames:
      - fs_list_dir
      - fs_find
      - fs_read_file

  - text: |
      In `C:\projects\thies\dluc\dluc_wins\DlucFlutterUI\`:
      1. Create/update a detailed `implementation_plan.md` breaking down:
         - Architecture (Riverpod providers, REST service layer, model definitions)
         - UI Screen mappings (WinForms forms -> Flutter Desktop screens)
         - Data table conversion using `data_table_2`
         - REST client endpoints and DTO models for http://localhost:5000
         - Multiplatform desktop configuration (Windows & Linux GTK)
      2. Create `tasks.md` with an actionable checklist (`- [ ]`) for phase-by-phase execution.
      3. Use `web_search` if needed to verify latest pub.dev package APIs.
      
      Analysis Findings:
      ${tool_result}
    enabledToolNames:
      - fs_write_file
      - fs_read_file
      - web_search

  - text: |
      Review `tasks.md` in `C:\projects\thies\dluc\dluc_wins\DlucFlutterUI\` and begin initial Flutter project setup:
      1. Initialize Flutter project for Windows and Linux platforms if not yet initialized.
      2. Configure `pubspec.yaml` with `flutter_riverpod`, `data_table_2`, `dio`, `window_manager`, and `intl` (using `web_search` for compatible pub versions).
      3. Create core directory structure (`lib/core/`, `lib/features/`).
    enabledToolNames:
      - fs_read_file
      - fs_write_file
      - terminal_exec
      - web_search
---
# WinForms to Flutter Desktop Conversion Skill

An automated AgentSkill to analyze legacy Visual Studio C# WinForms applications and migrate them to modern Flutter Desktop (Windows & Linux).

## Key Architecture
- **State Management**: Latest Riverpod (`flutter_riverpod`, `riverpod_annotation`).
- **Data Tables**: `data_table_2` (replacing WinForms `DataGridView`).
- **Networking**: REST Client connected to default backend URL `http://localhost:5000`.
- **Target Platforms**: Windows & Linux desktop environments.

## Paths
- **Source WinForms Project**: `C:\projects\thies\dluc\dluc_wins\DlucWinApps\DlucWinsUI\`
- **Target Flutter Output**: `C:\projects\thies\dluc\dluc_wins\DlucFlutterUI\`

## CLI Execution
```bash
# Inspect skill details
tealkit skill info example_skills/winforms-to-flutter-skill.md

# Run the complete analysis and planning workflow
tealkit skill run example_skills/winforms-to-flutter-skill.md

# Or start interactive coding mode with this skill loaded
tealkit code --instructions example_skills/winforms-to-flutter-skill.md
```
