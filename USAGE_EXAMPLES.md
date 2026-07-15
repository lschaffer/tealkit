# TealKit Usage Examples

Real-life usage scenarios organized by platform and tool category.

---

## Mobile (Android / iOS) & Desktop (Local UI Mode)

TealKit runs in **local UI mode** on both mobile and desktop — the Flutter app handles all built-in tools directly (email, calendar, documents, web crawl/search, SSH, etc.) without any separate server process. No setup or backend required.

Optional: connect the UI app to a remote **TealKit Server** — a headless Dart server hardened inside a Docker container — for offloaded execution, 24/7 scheduled tasks, or shared tool access. The headless server can be deployed on Linux, macOS, or Windows (via WSL2). See the **Server Mode** section below for details.

---

### Google Calendar

**Scenario:** "What meetings do I have tomorrow? Summarize them."

> **Prompt:** "List my calendars, then list events for tomorrow. Summarize all events in a table with time, title, and location."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Gemini 2.5 Flash, Ministral 8B |
| Inbuilt Tools | `list_calendars`, `list_events`, `get_event` |
| Auth Required | Google OAuth (configured in Settings → Data Sources) |

**Scenario:** "Create a lunch meeting next Tuesday at 12:30 with John about Q3 planning."

> **Prompt:** "On my 'Work' calendar, create an event titled 'Q3 Planning — Lunch with John' next Tuesday at 12:30 PM for 1 hour. Set a reminder 15 minutes before."

| Field | Value |
|-------|-------|
| Inbuilt Tools | `list_calendars`, `create_event` |

---

### Gmail

**Scenario:** "Find the email thread about the server deployment from last week."

> **Prompt:** "Search Gmail for messages with subject containing 'server deployment' from last week. Show me the full content of the most recent one."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Gemini 2.5 Flash, Ministral 8B |
| Inbuilt Tools | `search_gmail`, `get_gmail_message` |
| Auth Required | Google OAuth |

**Scenario:** "Summarize unread emails from today and draft replies."

> **Prompt:** "Search my Gmail inbox for unread messages from today. Summarize each in one sentence, then for the most urgent one draft a polite acknowledgment reply."

---

### IMAP Email

**Scenario:** "Check my work email for important messages."

> **Prompt:** "Search my INBOX folder for emails from my boss received in the last 48 hours. Summarize the ones that mention a deadline or action item."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Ministral 8B, Llama 3.1 8B |
| Inbuilt Tools | `list_folders`, `search_emails`, `read_email` |
| Auth Required | IMAP credentials (Settings → Email) |

**Scenario:** "Send a follow-up email about the project status."

> **Prompt:** "Send an email to team@example.com with subject 'Project Status Update — Week 24' and body: 'Hi team, please share your weekly updates by EOD Friday. Thanks!'"

| Field | Value |
|-------|-------|
| Additional Tools | Email delivery service (SMTP configured in Settings) |

---

### Home Assistant

**Scenario:** "What's the temperature in the living room and turn on the kitchen lights."

> **Prompt:** "List all Home Assistant entities in the 'living_room' and 'kitchen' areas. Report the current temperature in the living room, then turn on the kitchen light."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Any model (tools are easy) |
| Inbuilt Tools | `list_ha_entities`, `get_ha_entity_state`, `control_ha_entity` |
| Configuration | Home Assistant URL + Long-Lived Access Token in Settings |

**Scenario:** "Create an automation that turns off all lights at 11 PM."

> **Prompt:** "Trigger the 'night_off' automation in Home Assistant. Then check if any lights are still on and report them."

| Additional Tools | `trigger_ha_automation`, `get_ha_history` |

**Scenario (Desktop/Headless):** (All Home Assistant tools also work in headless/server mode.)

---

### SSH / Remote Shell

SSH connectivity is configured per **SSH server profile** in Settings → Data Sources, or per-agent/playground session. The agent can only connect to servers you've explicitly configured.

**Configured SSH Server Example:**

**Scenario:** "Check disk usage on my web server."

> **Prompt:** "SSH into my 'web-server' profile and run `df -h`. Summarize which partitions are over 80% full."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Ministral 8B, Llama 3.1 |
| Tools | SSH MCP server (one per configured profile) |
| Configuration | SSH key or password in Settings → Data Sources, or per-agent connection details |

**Scenario:** "Restart nginx and verify it's running."

> **Prompt:** "SSH into my 'production' server profile, restart nginx with `sudo systemctl restart nginx`, then check its status. Report the result."

> **Note:** When no SSH server profile name is given, the agent asks which configured server to use. You can also provide connection details directly in an agent's prompt for ad-hoc usage.

---

### Web Search & Research

**Scenario:** "What are the latest AI news today?"

> **Prompt:** "Search the web for the latest AI news from today. For each result, give me the title and a 1-sentence summary."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Gemini 2.5 Flash |
| Inbuilt Tools | `web_search` |
| Configuration | SerpAPI / Serper.dev / DuckDuckGo (auto fallback) |

**Scenario:** "Research and compare prices for flights to Barcelona next month."

> **Prompt:** "Search for round-trip flights from Vienna to Barcelona for next month. Compare prices across dates and airlines in a table."

---

### Indexed Website Search

**Scenario:** "Find the API documentation for the authentication endpoint on our docs site."

> **Prompt:** "Search indexed pages on docs.example.com for 'authentication API endpoint'. Show me the relevant page content."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Recommended LLM | Any model |
| Inbuilt Tools | `search_indexed_websites`, `get_indexed_page`, `index_websites` |

---

### Google Drive

**Scenario:** "Find the budget spreadsheet from last quarter."

> **Prompt:** "Search Google Drive for files named 'budget' from Q1 2025. Show me the file names and their locations."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Inbuilt Tools | `search_drive`, `list_drive_folder`, `read_drive_file` |
| Auth Required | Google OAuth |

---

### Python Tools (Desktop & Server)

**Scenario (Desktop/Headless):** "Analyze this CSV data for me."

> **Prompt:** "List available Python tools, then run 'csv_analyzer' on this CSV data: [paste CSV]. Show me summary statistics for all columns."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless server (not mobile standalone) |
| Recommended LLM | Any model with tool calling |
| Inbuilt Tools | `list_py_tools`, `init_py_tool`, `run_py_tool`, `csv_analyzer`, `json_query`, `text_classify` |
| Note | On mobile, Python tools run on the connected TealKit server |

**Pre-installed Python tools:**
| Tool | Description |
|------|-------------|
| `csv_analyzer` | Column-level statistics on raw CSV data |
| `json_query` | Query/transform JSON data with JMESPath expressions |
| `text_classify` | Classify text by matching keywords or patterns |

---

### Documents & Indexing

**Scenario:** "Search my indexed documents for the contract with ACME Corp."

> **Prompt:** "Search indexed documents for 'ACME Corp contract'. Show me the content of the most relevant document."

| Field | Value |
|-------|-------|
| Platform | Mobile / Desktop |
| Inbuilt Tools | `search_documents`, `get_document_content`, `reindex` |

---

## JavaScript Tool Generation (Mobile)

On mobile, you can create custom JavaScript tools directly from a prompt. The LLM generates the JS code, which gets stored and is immediately available as an MCP tool.

**Example:** Create a currency converter tool.

> **Prompt:** "Create a JavaScript tool called 'currency_convert' that converts between USD, EUR, and GBP using live exchange rates from exchangerate-api.com. The tool should accept `amount`, `from_currency`, and `to_currency` as parameters. It should fetch the rate from the API and return the converted amount."

**What happens:**
1. The LLM generates the JavaScript code with proper input schema
2. The tool is stored via `init_js_tool` / `run_js_tool`
3. A dynamic MCP tool `js_currency_convert` becomes available immediately
4. Next time you can just say: "Convert $50 USD to EUR"

**Another example:** Create a QR code generator.

> **Prompt:** "Create a JavaScript tool called 'generate_qr' that accepts `text` (string) and `size` (optional integer, default 200). It should generate a QR code using `https://api.qrserver.com/v1/create-qr-code/?size={size}x{size}&data={text}` and return the image as a Markdown image link."

> **Then use it:** "Generate a QR code for https://tealkit.app with size 300."

---

### Tips for JS Tool Generation on Mobile

| Tip | Description |
|-----|-------------|
| **Describe clearly** | Tell the LLM exactly: tool name, input parameters, output format |
| **Use public APIs** | JS tools run in a sandboxed Deno environment — they can make HTTP(S) fetches to public APIs |
| **Keep it stateless** | Each invocation is stateless; use the tool's arguments for all input |
| **Return structured data** | Return JSON objects so the LLM can format responses nicely |
| **Reuse tools** | Once created, tools persist and can be chained together by the LLM |

---

## Desktop / Headless Mode

In desktop or headless server mode, TealKit unlocks additional capabilities through direct filesystem access, local MCP servers, and subprocess execution.

---

### Filesystem Tools

**Scenario:** "Organize my Downloads folder."

> **Prompt:** "List the contents of my Downloads folder. Group files by type (PDF, images, archives, documents) and create subfolders for each group, then move the files into their respective folders."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless |
| Recommended LLM | Any model |
| Inbuilt Tools | `list_directory`, `read_file`, `make_directory`, `execute_command` |

**Scenario:** "Find all TODO comments in my project."

> **Prompt:** "Recursively search my project folder ~/projects/myapp for files containing 'TODO' or 'FIXME'. List each occurrence with filename and line number."

---

### GitHub MCP Server (Free)

**Scenario:** "Clone a repo, create a branch, and push a change."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless |
| Recommended LLM | Any model |
| External MCP | [`@modelcontextprotocol/github`](https://github.com/modelcontextprotocol/servers/tree/main/src/github) (free, open-source) |
| Installation | Via TealKit MCP Server Registry or manual config |

**How to install (in app):**
1. Go to **Settings → MCP Servers → Discover**
2. Search for "GitHub MCP Server" in the registry
3. Click **Install** — TealKit downloads and configures it automatically
4. Provide your GitHub Personal Access Token

**Example usage after installation:**

> **Prompt:** "Search my GitHub repos for 'teal' in the name, then list the open issues in the most recent one."

> **Prompt:** "Create a new repository called 'my-notes', add a README.md with a description, and push an initial commit."

---

### Filesystem MCP Server (Free)

**Scenario:** "Read, edit, and create files anywhere on the filesystem."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless |
| External MCP | [`@modelcontextprotocol/filesystem`](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) |
| Capabilities | Read, write, move, search files, get file info |

**Example:**

> **Prompt:** "Read ~/config.json, add a new key `"feature_x_enabled": true` to the JSON, and save it back."

---

### Web Scraping & Puppeteer MCP Server (Free)

**Scenario:** "Take a screenshot of a webpage and extract data."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless |
| External MCP | [`@modelcontextprotocol/puppeteer`](https://github.com/modelcontextprotocol/servers) |

**Example:**

> **Prompt:** "Navigate to https://example.com, take a screenshot, and extract all the text content from the page."

---

### SQL / Database MCP Server (Free)

**Scenario:** "Query a local SQLite database."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless |
| External MCP | [`@modelcontextprotocol/sqlite`](https://github.com/modelcontextprotocol/servers) |

**Example:**

> **Prompt:** "Connect to the SQLite database at ~/data/mydb.sqlite, list all tables, and show me the schema of the 'users' table."

---

### Python Tools (Desktop / Headless)

Full Python tool support is available on desktop and server mode. The same Python tools (`csv_analyzer`, `json_query`, `text_classify`) come pre-installed. Additional custom Python tools can be created:

> **Prompt:** "Create a Python tool called 'sentiment_score' that accepts text input and returns a sentiment score from -1.0 to 1.0 using VADER (install the `vaderSentiment` package)."

The LLM will:
1. Generate the Python code with proper `execute(args)` function
2. Define the JSON Schema input schema
3. Store the tool via `init_py_tool`

---

### Scheduled Agents (Desktop / Headless)

**Scenario:** "Check the weather every morning and send me an email."

> **Agent Prompt:** "Every morning at 7 AM, get the current weather for Vienna, and email me a brief summary to my@email.com. Only email if there's rain or extreme temperatures forecast."

| Field | Value |
|-------|-------|
| Platform | Desktop / Headless |
| Required Tools | `get_current_weather`, `send_email` (IMAP/SMTP) |
| Schedule | Cron (set in agent editor) |

**Scenario:** "Monitor disk space weekly."

> **Agent Prompt:** "Every Monday at 9 AM, SSH into my server, check disk usage with `df -h`, and alert me if any partition exceeds 85% usage."

---

## Architecture Overview

```
                          ┌─────────────────────────────────────┐
                          │         TealKit (any platform)       │
                          │                                     │
                          │  Flutter UI (Chat / Settings / ...)  │
                          │         │  MCP over localhost       │
                          │         ▼                           │
                          │  On-Device Dart Server              │
                          │  ┌───────────────────────────────┐  │
                          │  │ Internal MCP Servers:         │  │
                          │  │ • Calendar (Google)           │  │
                          │  │ • Gmail / IMAP Email          │  │
                          │  │ • Home Assistant              │  │
                          │  │ • Web Search & Index          │  │
                          │  │ • Documents                   │  │
                          │  │ • Google Drive                │  │
                          │  │ • SSH (per configured profile)│  │
                          │  │ • Weather / Timezone          │  │
                          │  │ • PDF / Excel / Chart Gen.    │  │
                          │  └───────────────────────────────┘  │
                          │                                     │
                          │  Desktop-only Additions:            │
                          │  ┌───────────────────────────────┐  │
                          │  │ • Python Bridge (py_bridge)   │  │
                          │  │ • JavaScript Bridge (Deno)    │  │
                          │  │ • Shell / Subprocess          │  │
                          │  │ • External MCP Servers:       │  │
                          │  │   - GitHub                    │  │
                          │  │   - Filesystem                │  │
                          │  │   - Puppeteer / Playwright    │  │
                          │  │   - SQL / Docker / etc.       │  │
                          │  └───────────────────────────────┘  │
                          └─────────────────────────────────────┘
```

### Key Differences by Platform

| Capability | Mobile (Standalone) | Desktop (Win) | Desktop (Mac/Linux) | Headless Server |
|-----------|-------------------|--------------|--------------------|-----------------|
| Google Calendar / Gmail | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| IMAP Email | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Home Assistant | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Web Search & Indexing | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Documents | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Google Drive | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Weather / Timezone | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Charts / PDF / Excel | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| SSH (configured profiles) | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| JS Tool Bridge (Deno) | ✅ Built-in | ✅ Built-in | ✅ Built-in | ✅ Built-in |
| Python Tool Bridge | ❌ | ✅ Native | ✅ Native | ✅ Native |
| PowerShell Scripts | ❌ | ✅ Native | ❌ | ❌ |
| Shell / Subprocess | ❌ | ✅ Native (pwsh) | ✅ Native (bash) | ✅ Shell |
| External MCP (GitHub, FS, etc.) | ❌ | ✅ Native | ✅ Native | ✅ Native |
| Scheduled Agents | ⚠️ Via OS tasker | ✅ Task Scheduler | ✅ cron / launchd | ✅ Built-in cron |

> **✅** = works out-of-the-box on this platform
> **⚠️** = limited support or requires additional setup
> **❌** = not available (platform restrictions)

---

## Model Selection Guide

Choosing the right model depends on expected output length, tool complexity, and device capabilities.

### Context Window vs. Expected Output

| Task Type | Expected Tool Output | Recommended Min. Context | Recommended Model Class |
|-----------|-------------------|------------------------|------------------------|
| Quick lookup (weather, time, simple calc) | < 500 chars | 4K | Embedded (3B-7B), Ministral, Phi |
| Email search & summarize (5-10 results) | 1K - 5K chars | 8K - 16K | Ministral 8B, Llama 3.1 8B, Gemma 2 9B |
| Web search (5-10 results with snippets) | 2K - 8K chars | 8K - 32K | Gemini 2.5 Flash, Qwen 2.5 14B |
| Web page content extraction | 5K - 50K chars | 32K - 128K | Gemini 2.5 Flash, Llama 3.1 70B, GPT-4o mini |
| Document search + full content read | 10K - 100K chars | 64K - 1M | Gemini 2.5 Pro, GPT-4o, Claude 3.5 Sonnet |
| File listing + directory tree | 1K - 10K chars | 8K - 32K | Any model ≥ 8K ctx |
| CSV/JSON analysis via Python tool | 2K - 20K chars | 16K - 64K | Gemini 2.5 Flash, Qwen 2.5 32B |
| Home Assistant: entity list + states | 1K - 5K chars | 8K | Any model with tool calling |
| SSH command output (df -h, ps aux, logs) | 500 - 20K chars | 8K - 32K | Ministral 8B, Llama 3.1 8B+ |
| Indexed website crawl (multi-page) | 20K - 200K chars | 64K - 1M | Gemini 2.5 Pro, GPT-4o |
| Email + Calendar + Drive combined query | 5K - 30K chars | 32K - 128K | Gemini 2.5 Flash, GPT-4o mini |

### When to use Embedded (On-Device) Models

| Suited For | NOT Suited For |
|-----------|---------------|
| ✅ Single-tool calls with short output | ❌ Web page content extraction (>5K chars) |
| ✅ Weather, time, calculator | ❌ Document search with full content reads |
| ✅ Simple Home Assistant commands | ❌ CSV/JSON analysis (tool output too large) |
| ✅ Quick email count/check | ❌ Multi-tool chains with large intermediate results |
| ✅ SSH command + short response | ❌ Any task where tool output exceeds ~2K chars |
| ✅ Web search (headline-level only) | ❌ Image analysis (requires separate multi-modal model) |

> **Rule of thumb:** If a task reads files, web pages, or documents, use a cloud model with ≥32K context.

---

## Sub-Prompt Chaining for SLM & Embedded Models

Sub-prompts let you break a complex task into sequential steps, each with its own tool set and stop behavior. This is ideal for small/embedded models (3B-7B) that struggle with complex multi-step reasoning.

### Syntax Reference

| Syntax | Meaning |
|--------|---------|
| `++#++` | Step separator (continue with all tools) |
| `++#++[NT:]` | Next step: no tools (text-only LLM response) |
| `++#++[NT:tool1\|tool2]` | Next step: only these tools available |
| `++#++[SATC]` | Stop after tool call (don't send result back to LLM, go to next step) |
| `++#++[NT:tool1][SATC]` | Combine: only tool1, stop after call |

### Example 1: Fetch + Format (Disk Usage Report)

Perfect for SLM (3B-7B) — each step is a single, focused instruction.

```
Call the ssh function called 'disk_usage' on my configured 'web-server' profile to get the current disk usage. Return the raw JSON output.
++#++[NT:][SATC]
Create a markdown report from ${tool_result}. Format it as:

## 🖥️ Server Disk Usage Report

| Filesystem | Size | Used | Avail | Use% | Mounted |
|-----------|------|------|-------|------|---------|
| ... rows from tool result ... |

**Status:** ⚠️ Warning if any partition > 80%, else ✅ All healthy.
```

| Step | Tools | Stop After Call | Purpose |
|------|-------|----------------|---------|
| 1 | All (SSH `disk_usage`) | No | Execute SSH command, return JSON |
| 2 | No tools | ✅ Yes | Format JSON into markdown via LLM |

**Recommended models:** Ministral 8B, Phi-4 14B, Llama 3.1 8B (step 1 only needs tool calling; step 2 is pure text generation).

### Example 2: Email Summary with Web Context (Multi-Tool)

```
Search my Gmail inbox for unread emails from the last 24 hours. Return the raw results.
++#++[SATC]
For each email that mentions a company or product, search the web for that company's latest stock price or news.
++#++[NT:web_search][SATC]
Combine the email summaries and web results into a single markdown briefing.

**Morning Briefing — {date}**

### 📬 Unread Emails
| From | Subject | Key Point |
|------|---------|-----------|
| ... | ... | ... |

### 🔍 Web Context
- Company X: latest news ...
- Company Y: stock price ...
```

| Step | Tools | Stop After Call | Purpose |
|------|-------|----------------|---------|
| 1 | All (Gmail) | ✅ | Get emails, stop, don't process yet |
| 2 | `web_search` only | ✅ | Research context for each mention |
| 3 | No tools | No | LLM writes final formatted summary |

**Recommended models:** Gemini 2.5 Flash, Qwen 2.5 14B, GPT-4o mini.

### Example 3: No-Tools Final Formatting Step

Useful when you want the LLM to reformat tool output without calling more tools.

```
Search my calendar for events today.
++#++[NT:]
From the tool result, create a nice agenda layout using markdown with emojis:

## 📅 Today's Agenda — {date}

| 🕐 Time | 📍 Event | 📍 Location |
|---------|----------|-------------|
```

| Step | Tools | Purpose |
|------|-------|---------|
| 1 | All (Calendar) | Fetch events |
| 2 | No tools (`[NT:]`) | Pure formatting — model cannot call new tools |

---

## Scheduled Agents with Sub-Prompt Chaining

Scheduled agents can use sub-prompts to separate data collection from formatting, just like interactive sessions.

### Example: Server Health Monitor (Every 4 Hours)

**Agent Configuration:**
- **Schedule:** Every 4 hours
- **LLM:** Ministral 8B (small, fast, good tool calling)
- **System Prompt (Agent Prompt):**

```
++#++
Call the ssh function 'disk_usage' on my configured 'web-server' profile. Return the raw JSON result.
++#++[NT:ssh_disk_usage][SATC]
Call the 'get_ha_entity_state' for 'sensor.system_cpu_usage' and 'sensor.memory_usage' on my Home Assistant. Return the raw JSON.
++#++[NT:get_ha_entity_state][SATC]
Now create a combined markdown report from both tool results.

## 🖥️ Server Health Report — {datetime}

### 💾 Disk Usage
{formatted disk_usage result}

### ⚙️ System Resources
- CPU: {cpu_usage}%
- Memory: {memory_usage}%

### 🚦 Status
- Disk: ✅/⚠️/❌
- CPU: ✅/⚠️/❌
- Memory: ✅/⚠️/❌

++#++[NT:]
Send this report via email to admin@example.com with subject "Server Health Report — {datetime}".
```

**Step-by-step execution:**

| Step | Tools | Stop | What Happens |
|------|-------|------|-------------|
| 1 | All | No | Agent calls `ssh_disk_usage` → gets JSON |
| 2 | `get_ha_entity_state` | ✅ | Agent fetches CPU + memory from HA → stops |
| 3 | `web_search` | No | Agent formats both results into markdown |
| 4 | No tools | No | Agent writes final text (no new tools) |
| 5 | No tools | — | Agent invokes email delivery to send the report |

**Context window estimate:** ~3-5K tokens per run (small tool outputs + template). Suitable for Ministral 8B or Phi-4.

### Example: Conditional Chained Agent (Disk Alert → Create Ticket)

This pattern uses **two separate agents** where the second only runs if the first detects a problem.

**Agent 1: Monitor (Runs every hour)**
```
Call ssh 'disk_usage' on my 'web-server' profile. Return raw JSON.
++#++[SATC]
Analyze the disk usage JSON. If ANY partition is over 85% usage, output exactly:
  ALERT: {filesystem} at {use_pct}% on {server}
Otherwise output: OK
```

**Agent 2: Escalate (Triggered by Agent 1 output)**
```
Create a Google Calendar event titled "⚠️ Server Disk Alert — {filesystem}" starting in 15 minutes for 1 hour. Set the description to:
{alert_text}

Then send an email to admin@example.com with subject "🚨 URGENT: Server Disk Space Alert" and body containing the alert details.
```

| Agent | Schedule | Condition | Tools |
|-------|----------|-----------|-------|
| Agent 1 (Monitor) | Every hour | Always runs | SSH |
| Agent 2 (Escalate) | Not scheduled | Only if Agent 1 outputs `ALERT:` | Calendar, Email |

**How it works in TealKit:**
1. Agent 1 runs hourly, checks disk usage
2. If OK → outputs "OK" → nothing happens
3. If ALERT → output starts with "ALERT:" → TealKit's task output triggers Agent 2
4. Agent 2 creates a calendar event AND sends an alert email

**Context window estimate:** ~1-2K tokens per run (tiny). Works with any model including embedded 3B.

---

## In-Built Agent Configuration Switches

When editing an agent/task in TealKit, these switches control execution behavior:

| Switch | Location | Effect |
|--------|----------|--------|
| **Stop after tool call** | Per-sub-prompt step (`[SATC]` marker) or per-task toggle | LLM stops after first tool call; result goes to next step or final output |
| **Chat mode** | Agent editor → Chat mode toggle | Skips system prompt, warmup, tools, location injection — sends messages directly |
| **Per-step tool selection** | Sub-prompt editor (`[NT:tool1\|tool2]`) | Restricts which tools are available for each step |
| **Preset tool selection** | Agent editor → Tool preset | Pre-select a subset of all available MCP tools for the entire agent |
| **LLM override** | Agent editor → LLM config | Override which LLM provider/model this agent uses (overrides global setting) |
| **SLM mode** | Settings → LLM → SLM toggle | Uses shorter/directive system prompts, recommended for small local models |

### Recommended Switch Combinations

| Scenario | Recommended Settings |
|----------|--------------------|
| Embedded model (3B-7B) + single tool call | ✅ SLM mode ON, ✅ Native tool calling OFF, ✅ Safe tool call mode ON |
| Cloud model + web research | ✅ Native tool calling ON, ❌ Safe tool call mode OFF (native is reliable) |
| SLM + scheduled report | ✅ Sub-prompts with `[SATC]`, ✅ Per-step tool restriction (`[NT:]` for format step) |
| Multi-tool agent (any model) | ✅ Sub-prompts with tool restrictions, consider `[SATC]` between data + formatting |
| Quick chat (no tools needed) | ✅ Chat mode ON, ❌ preset tool selection = none |
