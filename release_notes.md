# Release Notes

This file tracks release changes by version.

## v1.6.7+140 - 2nd-Stage LLM Tool Filtering, Multi-Model Preselection & Anti-Loop Directives

### New Features & Enhancements
- **2nd-Stage LLM Tool Filtering & Preselection**:
  - Introduced an intelligent 2-stage tool routing pipeline via `LLMToolSelector` that reduces large toolsets (e.g. MCP servers with 10–20+ tools) down to the minimal 1–4 relevant tools per prompt turn.
  - Generates a compact tool manifest (summaries capped at 120 chars) and performs a fast, zero-shot structured tool preselection with zero temperature and a 120-token limit.
  - **$\le 5$ Tool Bypass**: When candidate or available tools are $\le 5$, 2nd-stage filtering is automatically bypassed to save latency and token overhead.
  - Seamlessly supported across both Local mode and Server / Multi-Agent mode on a per-step agent basis.
  - Robust fail-open design: Falls back to returning candidate tools if filtering times out or errors.
- **Configurable Tool Filter Model in LLM Settings**:
  - Added a dedicated "2nd Stage LLM Tool Filtering" settings section in `LLMSettingsDialog`.
  - Supports model selection dropdown (`LLM 1 (Primary)` vs `LLM 2 (Secondary)`), allowing users to leverage faster/cheaper secondary models for tool prefiltering.
  - Full persistence across secure storage, SharedPreferences shadow backups, and remote server state synchronization.
- **Tool Calling Loop Prevention & Anti-Loop Directives**:
  - Injected explicit anti-loop completion directives into tool output truncations (`[Instruction: Tool "$toolName" executed successfully. The data above is complete. Do NOT call "$toolName" again...]`) to prevent models from endlessly re-invoking tools.
  - Added an in-flight sequential repetition loop guard in `ChatService` preventing identical consecutive tool invocations.

## v2.0.19 / v1.6.6 - Skill Prompt Injection, Playground Workflow Persistence & Skill Editor Layout

### New Features & Enhancements
- **Skill Prompt Injection in Test Executions**:
  - Attached skills (`SkillDef`) are now automatically injected into the effective system prompt when testing prompts in the Workflow Editor and Workflow List execution flows.
  - Extended `TaskLlmOverrides` with `skillDefId` and `skillContent` overrides, ensuring test runs reflect the full prompt context (base system prompt + skill instructions + capability hints + tool hints).
- **Playground "Save as Workflow" with Skill Preservation**:
  - When saving prompts from the Playground into a workflow, attached skills are now mapped and persisted via `Agent.skillDefId`.
  - Opening the saved workflow in the Workflow Editor automatically restores the active skill chip, its instructions, and tool configurations.
  - Playground chat sessions now forward skill overrides to the active runtime provider.
- **Expanded Skill Editor / Wizard Layout**:
  - Updated the Skill Wizard dialog so the multiline Skill text editor dynamically expands to fill all remaining vertical space down to the footer actions bar.

## v1.6.1 / v1.0.191 - Settings Vault Skills, Talker Monitor & Layout Fixes

### New Features & Enhancements
- **Settings Vault Skills Export & Import**: Added full support for AgentSkills.io skill definitions (`SkillDef`) alongside Tool Hints (`FunctionHint`) under the selectable **Skills** checkbox (`includeSkills`) in the Settings Vault.
  - **Local & Server Mode Support**: Seamlessly exports and restores skills directly from the remote server endpoint in Server Mode, or from the local DuckDB database in Local Mode.
  - **Backward Compatibility**: Fully compatible with older `.tkv` vault files without a skills section, which are safely ignored during import.
- **Interactive Talker Log Monitor**: Added direct access to the live `TalkerScreen` log monitor with a dedicated bug report icon (`Icons.bug_report_outlined`) across all major app screens:
  - **Workflow List Screen**: Accessible via the AppBar actions (desktop) and mobile overflow popup menu.
  - **Playground Screen**: Accessible directly from the main toolbar action bar.
  - **Server Settings & Startup Wizard**: Integrated into the top AppBar action bar for instant debugging.
- **Standard Backup Skills Interoperability**: Updated standard JSON backup export (`exportSettings()` / `importSettings()`) to include `SkillDef` entries so all custom skills are preserved across standard backup/restore operations.

### Bug Fixes & Improvements
- **OpenAI-Compatible / DeepInfra `maxTokens: 0` Fix**: Fixed an `UnprocessableEntityException: Input should be greater than 0` error on OpenAI-compatible API providers (like DeepInfra) when tasks passed `maxTokens: 0`. Max tokens is now automatically normalized to `null` (omitted from the request payload) when non-positive.
- **`mcp-server-fetch` stdio Launch Fix**: Resolved an `ImportError: cannot import name 'McpError' from 'mcp.shared.exceptions'` error when launching stdio MCP servers via `uvx`. Automatically injects `--with mcp<1.3.0` into `uvx` executions for fetch MCP packages, ensuring `uvx` always uses `mcp<1.3.0` without requiring manual re-installation.
- **Model Option Layout Overflow Fix**: Fixed a right layout overflow issue (`RIGHT OVERFLOWED BY 38 PIXELS`) in the model Autocomplete dropdown option cards for long model name and pricing strings by wrapping price text in `Expanded`/`Flexible` containers with single-line text truncation.
- **UI Nomenclature**: Renamed the MCP server card button from `Build skills` to `Build hints`.

## v1.6.0 / v1.0.186 - LLM SDK Upgrades & Prompt Caching

### Improvements
- **LLM SDK Major Upgrades**: Upgraded all four LLM provider packages to their latest major versions with zero breaking API changes to existing code:
  - `googleai_dart`: 8.0.0 → **11.0.0** (Added Environments/Triggers APIs, ASR transcription, Gemini agent configs)
  - `openai_dart`: 7.0.0 → **8.0.0** (Added GPT-5.6 sync, explicit prompt caching, fast service tier, content provenance checks)
  - `anthropic_sdk_dart`: 5.0.0 → **7.0.0** (Added Dreams API, mid-conversation tool changes preserving prompt cache, Sonnet 5 support)
  - `ollama_dart`: 2.3.0 → **2.5.0** (Added tool-calling prompt renderer/parser config, files/adapters for model creation)
- **OpenAI Prompt Caching**: Automatically caches system prompts when tools are active, reducing token costs by 50%+ on repeated prompt prefixes during tool-calling loops. Cache key is derived from the system prompt content hash. Uses in-memory retention for local mode and 24-hour retention for server mode.

### Bug Fixes
- **Playground Model Option Fix**: Fixed an analysis error in the playground screen where inlined model option builder methods (`_buildMobileModelOption`/`_buildDesktopModelOption`) were not recognized by the Dart analyzer in large file contexts. Widgets are now built inline at the call site.

## v1.5.8 / v1.0.185 - Skill Gallery, Python Execution & Deduplication

### New Features
- **Skill Gallery — Browse & Import from OpenSkills.space**: New "Gallery" button in the Skills List screen opens the Skill Gallery dialog, which fetches the public skill catalog from `https://openskills.space/api/skills`. Browse, search, and multi-select skills, then import them directly into the local skill database. The API endpoint is read-only to ensure a curated experience. Imported skills are automatically validated against the agentskills.io YAML front matter format.
- **`run_python` Default Tool — Arbitrary Python Execution**: A new built-in Python tool (`run_python`) is automatically seeded into the Python Tool Library on first launch (or on next restart for existing installations). It accepts arbitrary Python code via the `code` parameter, executes it in a sandboxed process, captures stdout/stderr, and returns the output. This bridges the gap between LLM-generated Python code (from skills like PDF, data analysis, etc.) and actual execution — the LLM can now call `run_py_tool(toolName: "run_python", args: {code: "..."})` to run generated code instead of just outputting it as text.
- **Auto-Seeding of Missing Default Tools**: All database backends (client DuckDB, server DuckDB, server SQLite, server_light DuckDB) now check for missing default Python tools at startup and seed any that are absent. New installations get all four defaults (`csv_analyzer`, `json_query`, `text_classify`, `run_python`); existing installations automatically receive `run_python` on next restart without manual intervention.

### Improvements
- **Skill Import Deduplication**: `importFromFile()` now checks for existing skills by name (case-insensitive) before creating a new entry. Attempting to import a skill with a duplicate name throws a clear error message identifying the conflicting skill. This prevents accidental duplicate imports from the gallery, file picker, and all other import paths.
- **Gallery URL Read-Only**: The API endpoint field in the Skill Gallery dialog is now read-only, preventing accidental modification of the OpenSkills.space catalog URL.

## v1.5.7 / v1.0.183 - Skills Storage, Persistence & Management

### New Features
- **Skills Database & Persistence**: New `skill_defs` table in DuckDB (local/server) stores persistent AgentSkills.io skill definitions with name, goal, description, full skill markdown, and tool references. Skills survive app restarts and sync between sessions.
- **Skills List Screen**: New management screen in Global Settings (replaces the previous Skills card). Full CRUD: add new skills, edit existing ones, import from `.md`/`.zip` files with validation, export to `.md` files, and delete with confirmation. Each skill card shows name, description, and tool count.
- **Agent Model Extension**: Added `skillDefId` field to the Agent model in the `tealkit_api` package. When a skill is applied to a workflow agent, the skill ID is persisted in the workflow JSON. On workflow load, the skill is automatically looked up and applied.
- **Skill Wizard — Save/Cancel Mode**: When opened from the Skills List, the wizard shows Save + Cancel buttons instead of Apply. Skills are persisted to the database on save. Export and Import remain available; Generate Skill from Goal works as before.
- **Skill Import Validation**: Imported `.md` files are validated for valid agentskills.io YAML front matter (`---` delimiters, required `name` field). Invalid files are rejected with a clear error message.

### Playground & Workflow Editor
- **Skill Chip in Playground**: Applied skills appear as a clickable chip above the prompt (not injected directly into system prompt). Click reveals full skill text; wizard icon re-edits; X removes.
- **Skill Chip in Workflow Editor Agents**: Same chip pattern per agent. Click reveals skill in dialog; wizard button reopens pre-filled.
- **Settings Skills Section**: "Manage Skills" card opens the full Skills List Screen for browsing, editing, importing, and exporting skill definitions.

## v1.5.5 / v1.0.181 - Server Light Edition, Skill Import/Export Improvements & Output Cleanup

### New Features
- **Server Light Edition**: New lightweight server variant (`server_light`) designed for ARM devices and low-RAM environments (≤1 GB). Uses SQLite instead of DuckDB, excludes embedded model support, semantic search, website/document indexing, and PDF/chart tools. Shares the exact same REST API as the full server via a database adapter architecture — simply swap the backend at startup.
- **Skill Import Tool Detection**: Importing skills now shows a dialog listing all required capabilities (from `hermes.requires_toolsets`). Each tool can be individually enabled/disabled, with already-enabled tools shown as green checkmarks and missing tools pre-selected. After import, the playground stays on the setup screen instead of auto-starting.
- **Skill Export Hermes Format**: Exporting workflows now produces `agentskills.io` Hermes-compatible skill files with `metadata.hermes.requires_toolsets`, standard `version`/`author`/`license`/`platforms` fields, and the agent system prompt as the markdown body — no more proprietary `workflow` block or `capability://` URLs.
- **Server Output Auto-Cleanup**: Both server variants now run a periodic cleanup timer (every 30 minutes) that scans the output directory recursively and removes files/directories older than the configured retention days. Full logging shows scanned task/run counts, purged directories, and final summary.

### Bug Fixes & Improvements
- **DuckDB Connection Singleton**: Fixed a regression where the new adapter created multiple DuckDB connections to the same file, causing "file already open" errors from concurrent indexing/scheduler services.
- **Skill Import "capability://" Removal**: Eliminated fake `capability://` MCP tool entries that were created for unknown tools during skill import, which previously broke workflow execution.
- **Windows Data Directory**: Fixed server path resolution on Windows — now correctly uses `USERPROFILE` instead of falling back to `/root`.
- **Skill Import System Prompt**: Fixed an issue where the skill's system prompt text was duplicated into the initial prompt field on import.

## v1.5.4 / v1.0.175 - Automated Prompt Test & LLM Proxy Embedded Routing

### New Features
- **Automated Prompt Test Runner**: Replaced the legacy interactive chat bubble test feature in the workflow editor with an automated "Test" action dialog. Clicking the **Testen** button (available directly inline in the Prompts tab) executes step prompts sequentially using the active LLM configurations and MCP tools, reporting detailed log outputs of the execution.
- **Single Agent Prompt Scope**: Prompt test executions are now isolated to run only the prompt sequence, tool configurations, and LLM overrides of the currently selected agent (tab) in the workflow task, rather than executing all agents sequentially.
- **Playground Skill Tool Auto-Detection**: Importing skills now automatically scans for required tools, checking local libraries and active MCP server capabilities. Discovered tools are auto-enabled for prompt execution, and a post-import dialog presents a summary of resolved tools (green checkmark) vs. missing tools (orange warning).

### Bug Fixes & Improvements
- **LLM Proxy Embedded Provider Routing**: Resolved a server-side proxy issue where requesting the `Embedded (on-device)` provider in remote server mode threw an unsupported provider `BadRequestException`. Requests are now successfully intercepted and auto-routed to the server's local on-device embedded completions handler (`_handleEmbeddedChatCompletions`) for both `/llm` and `/llm2` proxy endpoints.
- **Import/Deduplication Fixes**: Removed legacy interactive chat bubble screen code, cleaned up all unused UI imports, and resolved Dart null-safety analyzer warnings.

## v1.5.3 / v1.0.160 - HTML Browser Preview, Playground Import Skills & Multi-turn Context Sync

### New Features
- **Default Browser HTML Preview**: Replaced the fullscreen in-app dialog and webview rendering. HTML snippets are written to a temporary local `.html` file with full page wrappers and opened in the user's default system web browser.
- **JavaScript Execution Warning**: Automatically displays warning banner inside the app's HTML preview card when `<script>` tags are present in the HTML block, suggesting the user open the interactive chart in their system browser.
- **Playground Import Skills**: Added an **Import Skill** button to the header of the Load Skills dialog, enabling direct parsing and importing of `.zip` (packed with `skills.md` / `SKILL.md`) or flat `.md` files. Includes automatic manifest validation and duplicate check alerts.
- **Hermes Skill File Import**: Added direct support for importing unstructured Hermes-style skill files (e.g., `docker-skills.md`). The parser automatically extracts the full instructional Markdown body following the YAML frontmatter and populates it as the `systemPrompt`, ensuring the Playground injects it as context.
- **Multi-turn Context Propagation**: Implemented automatic context carrying in both ChatService and server-side task runner. If a step prompt doesn't contain result placeholder tags, the output text of the previous step is automatically appended as context.
- **Python Tool Auto-Initialization**: Python tools now automatically initialize their virtual environments and install requirements on the first execution (in both workflows and playground runs) instead of returning a venv error. The execution logic is platform-aware, dynamically mapping the correct Python executable path for both Windows and Linux/macOS.

### Bug Fixes & Improvements
- **UI Nomenclature Refactoring**: Renamed all instances of "Tool Skills" to "Tool Hints" across UI screens, log events, and prompt configuration services to clearly describe their function as LLM tool-calling usage summaries.
- **Playground Venv State Synchronization**: Fixed a UI refresh issue where the list of Python tools would not update its venv state after successfully completing a local or remote initialization.
- **Scheduler Heartbeat Duplicates Fix**: Standardized scheduled executions to run using timezone-safe UTC timestamps (`.toUtc()`), and modified the server router update endpoint to preserve active execution states on synchronization requests, avoiding duplicate schedules/double emails.
- **Developer Credentials Clean-up**: Stripped all developer Google client IDs and GOCSPX client secrets from 17 launcher and installer scripts and documentation export configurations, replacing them with generic setup placeholders.

## v1.5.2 / v1.0.150 - LLM Stream Parsing Resilience & Unified Playground Skills

### New Features
- **Unified Playground Skills & Workflows**: Streamlined the playground saving and loading flow. Custom playground setups and single-agent workflows are now unified into standard `WorkflowTask` documents (where `agents.length == 1`), eliminating the legacy playground sessions database.
- **Interactive Save Dialog**: Renamed "Save setup" to "Save Skill / Workflow" which opens a simplified stateful dialog prompting for the skill name with checkboxes to save as a workflow (saving to the active local or remote database), save as a skill (generating a ZIP archive via `WorkflowExportService.exportWorkflow`), or both.
- **Load Skills Interface**: Renamed the "Sessions" button to "Load Skills" which displays a list of workflows filtered to keep only those with a single agent. Selecting a skill instantly populates the playground system prompts, user prompts, and LLM configuration.
- **Workflow Editor Transition**: Automatically navigates to the workflow edit screen after a workflow is saved from the playground, facilitating multi-agent development.
- **Cleaned Up Toolbar Actions**: Removed deprecated `Import session`, `Export session`, and `Save as task` options.

### Bug Fixes & Improvements
- **LLM SSE Stream Patching**: Upgraded the OpenAI HTTP client interceptor on both the client-side `LlmService` and server-side `ServerLlmRunner` to support dynamic, real-time Server-Sent Events (SSE) stream chunk transformation.
- **Stream Parse Exception Fix**: Resolved the `ParseException: Failed to parse chat stream event: type 'List<dynamic>' is not a subtype of type 'String?' in type cast` crash. The client now dynamically intercepts response chunks and converts empty content lists (`content: []` returned by some OpenAI-compatible models/proxies during tool call transitions) into standard null values.
- **Tool Call Stream Fix**: Ensured missing tool call `type: "function"` properties are dynamically injected during streaming completions.
- **Universal Provider Coverage**: Enabled the SSE stream patching automatically on client-side and server-side model runners for all OpenAI-compatible providers, ensuring robust behavior across third-party API backends, Ollama, and local model proxies.

## v1.4.6 / v1.0.149 - Agentic Skill Interoperability & Playground Auto-Skills

### New Features
- **Agentic Skill Interoperability**: Rewrote the import and export systems to comply with the standard `agentskills.io` specification. Workflows can now be exported as standardized `SKILL.md` markdown files (for pure instructions) or packaged as `.zip` archives.
- **Auto-Packaging of Custom Python Scripts**: When exporting workflows that reference custom Python tools, TealKit automatically bundles the `.py` source file and its `requirements.txt` under `scripts/` inside the ZIP archive. On import, custom Python scripts are dynamically unpacked and registered in the Python Tool Library.
- **Database Interoperability**: Import and export operations now read/write dynamically from whichever database is currently active (local SQLite/DuckDB or remote task server), ensuring seamless multi-device syncing.
- **Playground Auto-Skills**: Creating and testing agentic workflows in the Playground now automatically compiles and saves them as compliant skills when saved to your workflows.
- **Duplicate Check and Overwrite Dialog**: Importing duplicate skills with identical names now alerts the user via a confirmation dialog, allowing them to explicitly choose whether to overwrite the existing workflow.
- **Custom Skill Naming**: Provides an interactive filename customization dialog during exports, matching the app's vault backup flow.

### Bug Fixes & Improvements
- Removed unused dependencies and cleaned up build-time warnings.
- Mapped built-in native tools (e.g. weather, search) to generic, platform-independent capability dependencies (e.g. `weather_retrieval`) with a `compatibility` flag of `"TealKit-Native"`, preserving universal compatibility for other agent runtimes.

## v1.4.6 / v1.0.149 - Agentic function hint Interoperability & Playground Auto-function hints

### New Features
- **Agentic function hint Interoperability**: Rewrote the import and export systems to comply with the standard `agentskills.io` specification. Workflows can now be exported as standardized `SKILL.md` markdown files (for pure instructions) or packaged as `.zip` archives.
- **Auto-Packaging of Custom Python Scripts**: When exporting workflows that reference custom Python tools, TealKit automatically bundles the `.py` source file and its `requirements.txt` under `scripts/` inside the ZIP archive. On import, custom Python scripts are dynamically unpacked and registered in the Python Tool Library.
- **Database Interoperability**: Import and export operations now read/write dynamically from whichever database is currently active (local SQLite/DuckDB or remote task server), ensuring seamless multi-device syncing.
- **Playground Auto-function hints**: Creating and testing agentic workflows in the Playground now automatically compiles and saves them as compliant function hints when saved to your workflows.
- **Duplicate Check and Overwrite Dialog**: Importing duplicate skills with identical names now alerts the user via a confirmation dialog, allowing them to explicitly choose whether to overwrite the existing workflow.
- **Custom function hint Naming**: Provides an interactive filename customization dialog during exports, matching the app's vault backup flow.

### Bug Fixes & Improvements
- Removed unused dependencies and cleaned up build-time warnings.
- Mapped built-in native tools (e.g. weather, search) to generic, platform-independent capability dependencies (e.g. `weather_retrieval`) with a `compatibility` flag of `"TealKit-Native"`, preserving universal compatibility for other workflow runtimes.

## v1.4.4 / v1.0.148 - Multiple Server Connections & Concurrency Control

### New Features
- **Multiple Server Connections**: Manage a list of remote server configurations (`{name, url, apiKey}`) on both mobile and desktop platforms. Includes support for adding, editing, deleting, testing, and activating configurations. On upgrade, any legacy active server configuration is automatically migrated to the list as "Default Server".
- **Optional Server API Keys**: The API key is now optional. Server hosts can run TealKit without keys on local networks, and clients can leave the API key blank.
- **Server Concurrency Lock**: Added a bidirectional running lock on the server that prevents starting the same workflow/task concurrently via scheduler and REST API. Returns a `409 Conflict` warning showing `workflow is running already`.

### Bug Fixes & Improvements
- **Duplicate Executions Fix**: Background heartbeat tasks on the client app automatically skip execution when in remote server mode, avoiding duplicate runs and double emails.
- **Scheduler Dialog Fixes**: Clamped the monthly day selection between 1 and 28 and automatically rounded ad-hoc minute values to the nearest multiple of 5 in the scheduler picker to prevent Flutter crashes.
- **Task List UI**: All scheduled tasks now consistently display a green clock icon in the desktop table view, matching their scheduling state.

## v1.4.3 / v1.0.139 - Multi-workflow Flow Canvas & Unified LLM Configurator

### New Features
- **Visual Builder Execution**: Run multi-workflow orchestrations directly from the interactive flowchart canvas. Displays active progress spinners on currently running workflows and includes a red stop button in the top bar to terminate running flows instantly.
- **Improved workflow Nodes**: Clicking the execution status badge (Success, Error, Inactive) on any subagent node card displays the full step-specific prompt, tool calls, and outputs in an overlay dialog (desktop) or full-screen view (mobile).
- **Unified LLM Settings Widget**: Standardized the LLM configuration form across the primary settings dialog, subagent visual builder editor, and task/workflow editor. It unified model autocompletes, test connections, and advanced model options (SLM, multimodal, reasoning limits).
- **Smooth Split-screen Resizing**: Rewrote the desktop split-view resizing logic to accumulate relative drag deltas directly, resolving a layout latency lag and keeping the divider in perfect synchrony with the cursor.

### Bug Fixes & Optimizations
- General bug fixes and performance enhancements, including stable tool call IDs for server mode, remote log association for visual builder execution, mobile scheduler dialog dismissal fixes, and carriage return tolerance for Windows sub-prompt sequence separators.

## v1.4.1 / v1.0.134 - Workflow Visual Builder & Orchestration

### Improvements
- **Workflow Visual Builder**: Introduced an interactive 2D flowchart visual canvas supporting zoom, pan, and auto-centering to easily design, configure, and visualize multi-workflow orchestrations.
- **Workflow Orchestration & Routing**: Build complex multi-workflow pipelines and workflows with sequential or conditional routing rules directly inside the updated workflow editor. Features include defining fallback routes, custom variable evaluation (including LLM-based choices), and multiple conditional branching paths.
- **Dynamic UI & Visual Canvas Integration**: Polished visual builder link layouts (with continuous route lines) and streamlined scheduler management, enabling seamless configuration of orchestration flows across local and server modes.
## v1.3.8 / v1.0.132 - Local Model Importing & Live Token Cost Badge

### Improvements
- **Local Model Importing**: Added "Add GGUF from Disk" option to the embedded model picker, enabling users on desktop/local platforms to import `.gguf` model files directly from local storage.
- **Live Token Cost Badge**: Exposed live cached pricing state for LLM models and integrated a green `live` badge in the Playground workflow inspector showing when pricing details are fetched live from OpenRouter.

## v1.3.7 / v1.0.131 (Latest) - Native AI SDK Migration & Ollama/SLM Loop Interception

### Improvements
- **AI SDK Upgrade & LangChain Removal**: Upgraded core AI SDK dependencies (`openai_dart ^7.0.0`, `anthropic_sdk_dart ^5.0.0`, `ollama_dart ^2.3.0`, `googleai_dart ^8.0.0`) and completely removed all `langchain` wrapper packages in favor of native provider integration. Rewrote client-side and server-side model runners to utilize direct native SDKs.
- **Ollama Loop Prevention Enhancements**: Pair-implemented client-side, server-side, and playground enhancements for small models (Ollama/SLMs) to intercept and prevent repetitive tool execution loops:
  - Generates stable, unique deterministic tool call IDs based on function names and parameter argument hashes (rather than random UUIDs or shifting timestamps), allowing robust turn-by-turn comparison.
  - Formats all tool results returned to Ollama in a structured JSON payload with explicit `tool_executed: true` and `tool_result` attributes.
  - Dynamically injects loop prevention instructions into Ollama system prompts.
- **Embedded llamadart Upgrade**: Upgraded the GGUF local model execution bindings (`llamadart` version to `^0.8.10`).

## v1.3.6 / v1.0.130 - SDK Migration & Repeated Tool Call Loop Prevention

### Improvements
- **SDK Migration to `googleai_dart`**: Fully migrated the repository from the deprecated `google_generative_ai` package to the modern `googleai_dart` SDK (version `3.0.0`) for both the mobile/desktop app and the headless server. This update improves API compatibility, resolves type-safety issues, and provides alignment with `langchain_google` transitive dependencies.
- **Repeated Tool Call Loop Prevention**: Added a robust self-correcting loop interception mechanism for language models (specifically beneficial for small or embedded models that get stuck requesting the same tools repetitively):
  - Tracks executed tool call IDs and call signatures (`name|arguments`) dynamically during each conversation turn.
  - Automatically intercepts repeat tool calls, injecting a corrective result showing the previous successful execution result instead of re-running the tool.
  - Temporarily disables tools for subsequent turns in the chat sequence, physically forcing the model to write the final text response.
  - Structured non-binary tool execution outcomes as JSON payloads (`{"tool": "name", "id": "unique_id", "tool_executed": true, "tool_result": "..."}`) to help small models explicitly reason about executed tools.
  - Added loop prevention instructions into the system prompts.

## v1.3.5 / v1.0.128 - Remote Tool Sync, SFTP Fixes, & Output/Layout Polish

### Improvements
- **Remote Script & Tool Library Synchronization**: Added remote synchronization for the **SSH Script Library**, **Python Tool Library**, and **JavaScript Tool Library** when connected to a remote server. Tool and script CRUD operations automatically sync to the server's database (`scripts.json`, `py_tools`, and `js_tools` in DuckDB), allowing multiple client devices connected to the same server to share identical libraries.
- **Binary Tool Output Extraction**: Enhanced the LLM runner on the server to automatically extract binary output (such as generated charts or files) during tool execution and save them to the run's output directory.
- **Settings Vault Key Export/Restore**: Settings Vault now includes the remote server API key (`server_api_key`) in export packages, ensuring it is correctly restored when importing settings.
- **Dependency Update**: Replaced local path dependency for `dartssh2` with the pub.dev version `^2.18.0`.

### Bug Fixes
- **Playground SFTP Settings Preservation**: Fixed an issue where SFTP server settings were not saved/loaded correctly inside custom MCP tool setups in the Playground. SFTP override settings are now preserved across saves and correctly restored in the UI.
- **UI Layout Fixes**:
  - Fixed a UI overflow error on narrow mobile screens (RIGHT OVERFLOWED BY 20 PIXELS) by wrapping the `Configuration Required` dialog title in an `Expanded` widget.
  - Wrapped the AI generation prompt section in the script editor in a `Wrap` layout instead of `Row` to prevent UI layout errors on narrow mobile devices.
- **Execution Log Notifications**: Fixed an issue where the execution log was always included/uploaded/emailed regardless of notification settings. The execution log is now omitted if the `addExecutionLog` toggle is disabled in the workflow editor settings.

## v1.3.3 / v1.0.125 - Safe Tool Call Mode (Grammar-Constrained Decoding)
 
### Improvements
- **Responsive desktop split-view layout** — Added support for screen widths > 1200px. When active, it displays a left-hand navigation sidebar (width < 200px) with app branding, navigation buttons for Playground, Tasks, and Settings, and a compact Server/Local mode toggle, leaving the right-hand panel for the selected screen. Dynamically falls back to the original dashboard layout on smaller screens.
- **UI design style toggle** — Added support in settings to toggle between Modern UI (featuring glassmorphism, violet-cyan gradients, and particle background animation) and Classic UI.
- **Constellation background animation updates** — Enabled the constellation particle background animation across the main screens in desktop split-view layout, classic mobile layout, and modern mobile layout.
- **Safe tool call mode** — New per-provider toggle for Ollama that uses grammar-constrained decoding to prevent malformed tool calls. When enabled:
  - Native tool definitions are omitted from the request, forcing the model to use the prompt-instructed text-based tool call format
  - Response is parsed via `parseSafeToolCallResponse()` for reliable JSON extraction
  - Falls back gracefully to standard text-based parsing on failure
  - Works independently of the existing native tool calling toggle (both on/off combinations valid)
- Added GBNF grammar generator utility (`GrammarGenerator`) that converts MCP tool schemas into formal grammars for future constrained-decoding integration
- Exposed the new setting via server REST API (`use_safe_tool_call`) for headless/server mode
- Added English and German localization strings for the new UI toggle

### Bug Fixes
- Generic bug fixes and stability improvements.

## v1.3.2 / v1.0.124 - Multi-Modal Toggles, Model Prefetching & Improved Attachments

### Improvements
- Added support to switch between multi-modal and pure text models dynamically across settings (LLM 1, LLM 2, Embedded, Playground, Task editor).
- Added prefetch capability for available models in settings (Ollama, OpenAI, OpenAI-compatible, Mistral) with autocomplete suggestions.
- Improved attachment handling, including PDF/text text-extraction fallback for text-only models.
- Seeded **3 default Python tools** (`csv_analyzer`, `json_query`, and `text_classify`) out-of-the-box in both Desktop and Serverless/Server modes, allowing immediate stdlib-only Python execution.
- General performance and stability improvements.

### Bug Fixes
- Generic bug fixes and stability improvements.

## v1.3.0 / v1.0.124 - Website Indexing workflow Tool & macOS MCP Server Support

### Improvements
- Improved the built-in website indexing workflow tool with dynamic indexing support before workflow startup, and added a `sites` parameter to the `index`/`reindex` tools so the workflow can directly start crawling specific websites.
- macOS direct download version now supports local MCP servers (Python, Node.js) outside the sandbox — full MCP server runtime without Mac App Store restrictions.
- General performance and stability improvements.

### Bug Fixes
- Various bug fixes and reliability improvements across the platform.

## v1.2.6 / v1.0.113 - Ollama Native Tool Calling & SLM Tool Call Formatting

### Improvements
- Added support for Native Tool Calling toggle option to Ollama chat runner.
- Added UI toggle controls in LLM settings dialog to select native tool calling for Ollama, complete with German and English localization updates.
- Added a mandatory JSON tool call format instruction block to system prompts to enforce correct formatting on SLM and Qwen models.
- Enhanced the system prompt viewer dialog with responsive width/height layout and scrollability.

### Bug Fixes
- Fixed parsing/handling bugs for SLM/Qwen models in chat service and LLM runner.
- Fixed Ollama model download and configuration issues.

## v1.2.5 / v1.0.109 - GitHub MCP Runtime Fixes

### Improvements
- Improved pip-based MCP install handling for GitHub requirements URLs by normalizing `github.com/.../blob/.../requirements.txt` links to raw URLs.
- Added automatic Playwright browser installation on Windows for Python MCP servers so screenshot/navigation tools can start without a manual `playwright install` step.
- Added runtime recovery for missing Python virtual environments and prevented requirements-only repos from launching as `python -m <requirements.txt>`.

### Bug Fixes
- Fixed launch failures caused by treating requirements files as executable Python modules.
- Fixed discovery timeouts for Playwright-based Python MCP servers when Chromium was missing from the local Playwright cache.
- Fixed manual MCP entry persistence so `entryPoint` is retained for installed servers.

## Mobile/Desktop App (Local Mode) - v1.2.4

### Improvements
- Added per-step stop-after-tool-call support in sub-prompts (stop tool per prompt step behavior).
- Improved sub-prompt execution flow so marker-based prompts are always processed as sub-prompt sequences (even when only one step is present).
- Enforced strict named-tools behavior for sub-prompt steps: selected tools are used as the final outbound tool set for that step.
- Added eager MCP tool discovery in server-mode playground/editor selection flow so selected MCP groups can populate tools before starting live chat.

### Bug Fixes
- Removed hardcoded tool-count limiting behavior (no provider/model-specific fixed cap).
- Fixed misleading tool logs by separating semantic prefilter information from final outbound tool count.
- Fixed task serialization so `chat_mode` and `stop_after_tool_call` are always written (including `false`), preventing stale true values after updates.

## Server Mode (Headless Server) - v1.0.100

### Improvements
- Added per-step stop-after-tool-call parsing in server sub-prompt execution.
- Added per-step stop-after-tool-call propagation in chained prompt execution.
- Added full stop-after-tool-call support in the server LLM runner for both embedded and LangChain paths.

### Bug Fixes
- Fixed sub-prompt/global stop behavior so chained steps stop correctly when tool-result passthrough is required.
- Improved server-mode tool picker behavior by enabling immediate remote MCP start/tools prefetch path used by the playground/editor flow.

---

Notes:
- Mobile app version is read from `pubspec.yaml` without build metadata: `1.4.4` (from `1.4.4+114`).
- Server version is read from `server/pubspec.yaml`: `1.0.148`.
