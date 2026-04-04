# 🐦‍⬛ TealKit
### The Privacy-First, Infinitely Extensible Agentic AI Platform for Mobile & Desktop

![TealKit](https://lschaffer.github.io/tealkit-privacy/images/tealkit_promo.png)

**TealKit** turns your phone and computer into a powerful agentic AI platform with autonomous agents, built-in tools, and unlimited extensibility. Write your own tools in **JavaScript, Python, PowerShell, or Bash** — or connect any MCP server — and let the AI use them autonomously. Provider-independent, fully customizable, and designed for privacy.

[**English User Guide**](https://lschaffer.github.io/tealkit-privacy/guide/) | [**Deutsches Handbuch**](https://lschaffer.github.io/tealkit-privacy/guide/de/) | [**Privacy Policy**](https://github.com/lschaffer/tealkit-privacy)

---

## 🆕 What's New

* **Chat Mode** — A new toggle in Playground and agent settings (Basic tab) that bypasses the system prompt and all tools, forwarding your message directly to the LLM. Perfect for SLMs doing pure text work — translations, formatting, summarisation — where tool overhead adds latency without benefit.
* **Agent Chaining (conditional & unconditional)** — Chain agents with or without an LLM-evaluated condition. Unconditional chaining always passes the result to the next agent. Conditional chaining evaluates an expression and routes to different follow-up agents depending on the outcome. The triggering agent's output is injected at the `[task_result]` placeholder in the chained agent's prompt.
* **Stop After Tool Call** — New option in agent and Playground settings. When enabled the agent runs exactly one tool call, then stops — handing the raw tool output directly as `[task_result]` to the next chained agent without any further LLM processing. Ideal for data-extraction pipelines where you want unmodified tool output to flow into a downstream agent.

---

## 🚀 Core Capabilities

### 🤖 AI Playground & Flexibility
* **Provider Independent:** Use leading providers like **Google Gemini, OpenAI GPT-5, Anthropic, and Mistral**.
* **🇪🇺 European Privacy & GDPR:** Data sovereignty matters. TealKit works fully with **Mistral AI** — a European provider headquartered in France that processes all data within the EU. Ideal for users and organisations where GDPR compliance is non-negotiable. Just enter your Mistral API key and your prompts never leave European infrastructure.
* **Small Language Models (SLM):** Not every task needs a powerful cloud model. Run lightweight SLMs on your own hardware with **Ollama**, **LM Studio**, or any OpenAI-compatible local endpoint — zero cloud costs, zero data sharing. Mark a model as **SLM** in LLM Settings to get a compact, action-focused system prompt that forces the model to call tools immediately instead of explaining its plan. For pure text tasks (translation, formatting, summarisation) enable **Chat Mode** to skip all tools and system prompt overhead entirely — the fastest path from prompt to response for SLMs.
* **Dual-LLM Setup:** Configure a secondary LLM (LLM 2) — for example a fast SLM for code tasks — and switch between them directly in the **Playground** with the LLM 1 / LLM 2 selector. Every model behaves differently; use the Playground to compare prompts across models and find the best fit for each task before automating it.
* **Local Intelligence:** Support for **Ollama** models for 100% offline processing.
* **Full Customization:** Tweak model parameters per task and keep token costs predictable.
* **Chat-to-Task:** Test ideas in the chat interface before promoting them to automated tasks.
* **Auto System Prompt:** Select tools and TealKit automatically generates a tailored system prompt via AI — editable before you start.

### 🛠 Built-in AI Skills
* **Document Intelligence:** Local RAG using **DuckDB**. Index PDFs, Word, and Excel files for instant semantic search across your device.
* **Digital Office:** Deep integration with **Gmail** and **Google Calendar** (free) + **Google Drive** (Pro) + universal IMAP/SMTP support.
* **Content & Visualization:** Generate files (TXT, PDF, Excel) and create **Mermaid** diagrams/flowcharts from any data.
* **Web Search & Indexing:** Perform live searches via **SerpApi** or **DuckDuckGo**, and crawl websites for local indexing.
* **Remote Management:** Manage servers via **SSH** on all platforms. On Desktop, generate and execute **Bash scripts** locally (Linux/macOS) or **PowerShell scripts** (Windows).

### ⚙️ Agentic Workflows & Automation
* **Autonomous Execution:** Schedule **cron-based** tasks that run in the background, even when the app is closed.
* **Agent Chaining:** Build multi-agent pipelines — with or without conditions. Chain agents unconditionally to always pass results forward, or add an LLM-evaluated condition (e.g., "If X is found, escalate, otherwise archive"). The triggering agent's output is available as `[task_result]` in the chained agent's prompt. Combine with **Stop After Tool Call** to pass raw tool output (e.g., SSH command result, web scrape) directly to the next agent without LLM reformatting.
* **Multi-Channel Output:** Save results to local storage, or send them via **Email, Slack, or WhatsApp** (with attachments).

---

## 💡 Real-World Examples

### 📱 All Platforms (Mobile + Desktop)

| Scenario | Tools | The Workflow |
| :--- | :---: | :--- |
| **The Daily Researcher** | Web + Email | Every morning at 8 AM, crawl 5 industry news sites, summarize key trends with Gemini, and email a PDF report for yourself. [▶ Watch demo](https://lschaffer.github.io/tealkit-privacy/videos/tealkit_android_web_index_crawl.mp4) |
| **The Server Guardian** | SSH + WhatsApp | Every hour, SSH into your server and check disk usage. If it exceeds 90%, send an alert to your WhatsApp. |
| **The Document Oracle** | RAG / Documents | Index 1000 pages of local technical manuals. Ask: *"What is the specific torque for the XJ-900 engine?"* and get an instant answer with citations. |
| **The Assistant** | Gmail + Calendar | Scan Gmail for invoices, automatically create a Calendar entry. [▶ Watch demo](https://lschaffer.github.io/tealkit-privacy/videos/tealkit_android_gmail_calendar.mp4) |
| **The Cost Analyst** | Gmail + Charts | Search Gmail for all invoices from your mobile provider this year, summarize the actual monthly costs, generate a pie chart from the data, and email you the chart and summary. [▶ Watch demo](https://lschaffer.github.io/tealkit-privacy/videos/tealkit_android_web_search.mp4) |
| **The Disk Watcher** | SSH + Email | In the **Shell Script Library**, generate a script named `disku` with prompt *"list disk usage of all mount points in MB, one per line"*. Create a task using the **SSH** tool: *"Call script disku, format the result as a modern styled HTML table with a color-coded status bar"*, output channel **Email**, scheduled **daily at 16:00**. |
| **The Smart Home Assistant** | Weather + Home Assistant MCP | Enable the built-in **Home Assistant** skill and connect it to your local HA instance. Create a task: *"Get the next 12-hour weather forecast for my location. If the avg temperature is above 15 degree, adjust target temperature of climate.ecobee between 19 and 22 otherwise between 20 and 23."* Schedule it **hourly** to keep your thermostat in sync with the outdoor forecast automatically. [▶ Watch demo](https://lschaffer.github.io/tealkit-privacy/videos/tealkit_desktop_smarth_1.mp4) · [▶ Demo 2](https://lschaffer.github.io/tealkit-privacy/videos/tealkit_desktop_smarth_2.mp4) |

### 🖥 Desktop Only

#### 🐙 GitHub Integration

| Scenario | Tools | The Workflow |
| :--- | :---: | :--- |
| **The GitHub Reporter** | GitHub MCP + FTP | Install the Node.js GitHub MCP server from GitHub in TealKit with your access token. Create a task: *"Scan this repository for changes since yesterday, write a formatted summary to a text file, and upload it to an FTP server"*, scheduled **daily at 08:00**. |

#### 🪟 Windows Administration

| Scenario | Tools | The Workflow |
| :--- | :---: | :--- |
| **The Downloads Janitor** | PowerShell + Email | **Step 1 — Script:** In the **PowerShell Script Library**, generate a script named `old_files` with prompt *"Accept a parameter DaysOld. Scan the current user's Downloads folder for files older than DaysOld days. Output each file as: path \| modified date \| size in KB. Sort ascending by modified date."* **Step 2 — Following agent:** Create an agent named `old_files_alert` with **Following agent mode** enabled and prompt *"You receive a list of old files. Send an email with subject 'Old files in Downloads' and the list formatted as an HTML table."* **Step 3 — Main agent:** Create a task using the **PowerShell** tool, prompt *"Call old_files 30. Format the output as a Markdown list."*, enable **Agent Chaining** with condition *"list count > 10"*, link to following agent `old_files_alert`, scheduled **daily at 07:00**. |

---

## 🔌 Extensibility — Add Any Skill, Connect Any Service

TealKit is an **open agentic platform**: every capability not built-in can be added as a custom AI skill or by connecting a third-party MCP server — no boilerplate, no backend required.

### Your Own AI Skills

| Skill Type | Platform | What You Can Do |
| :--- | :--- | :--- |
| **JavaScript** | All (Mobile + Desktop) | Write sandboxed custom skills directly in the app — no server, no install needed. |
| **Bash / Shell Script** | Desktop — Linux & macOS | Generate and run shell scripts locally; stdout/stderr feed straight back into the agent. |
| **PowerShell Script** | Desktop — Windows | Generate and execute PowerShell scripts for full Windows automation from a single prompt. |
| **Python MCP Server** | Desktop — all OS | Build complete MCP servers with the built-in editor, instant reload, and full library access. |

> **Syntax-highlighted code editor:** All script libraries (JS, Bash, Python, PowerShell) include a full-screen code editor with syntax highlighting and one-tap expand — making it easy to review, tweak, or copy generated scripts before saving.

### Connect to Existing MCP Servers

| Method | Platform | How It Works |
| :--- | :--- | :--- |
| **Import from GitHub** | Desktop | One-click install of any Node.js or Python MCP server straight from a GitHub repository URL. |
| **Glama** | All | Browse the Glama registry inside TealKit and connect any listed server with a single tap. |
| **Smithery** | All | Search the Smithery catalog directly from the app and register cloud-hosted MCP servers instantly. |
| **PulseMCP** | All | Discover servers from the PulseMCP directory and add them to your agent's toolset in one step. |
| **Custom URL** | All | Paste any MCP server URL (SSE or HTTP) to connect private or self-hosted servers. |

---

## 🆓 Free vs Pro

| Feature | Free | Pro |
| :--- | :---: | :---: |
| AI Playground (chat) | ✅ | ✅ |
| Global LLM 1 & 2 config | ✅ | ✅ |
| SSH server config & 1 script | ✅ | ✅ Unlimited |
| 1 JavaScript MCP tool | ✅ | ✅ Unlimited |
| 1 remote MCP server (Smithery / Glama / PulseMCP) | ✅ | ✅ Unlimited |
| Web search (SerpDev / SerpAPI / DuckDuckGo) | ✅ | ✅ |
| Gmail & Google Calendar | ✅ | ✅ |
| IMAP email | ✅ | ✅ |
| Interactive charts | ✅ | ✅ |
| File output, Calculator, Weather, Geolocation | ✅ | ✅ |
| 1 website to index (no auto-schedule) | ✅ | ✅ Up to 10 + auto-schedule |
| 1 document folder + 3 files to index (no schedule) | ✅ | ✅ Unlimited + schedule |
| 3 tasks | ✅ | ✅ Unlimited |
| **Desktop:** 1 Python MCP tool | ✅ | ✅ Unlimited |
| **Desktop:** 1 PowerShell script | ✅ | ✅ Unlimited |
| **Desktop:** Install 1 Python or Node.js MCP server | ✅ | ✅ Unlimited |
| PDF writer & generation | — | ✅ |
| Mermaid diagram PNG generator | — | ✅ |
| Excel export tool | — | ✅ |
| SFTP explorer | — | ✅ |
| Home Assistant integration | — | ✅ |
| Google Drive | — | ✅ |
| Backup & restore vault | — | ✅ |
| Agent chaining (conditional & unconditional) + Stop After Tool Call | — | ✅ |
| Save playground chat as task | — | ✅ |

---


**No TealKit Cloud.** Your private data, files, settings, and credentials remain in your device's secure storage. You choose the third-party providers you trust.

---

## 💻 Platforms

| Platform | |
| :--- | :--- |
| **Android** | [<img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" height="40" alt="Get it on Google Play"/>](https://play.google.com/store/apps/details?id=at.ls.gr.tealkit) |
| **Windows** | [<img src="https://get.microsoft.com/images/en-us%20dark.svg" height="40" alt="Get it from Microsoft"/>](https://apps.microsoft.com/detail/9nb8trlrgwr2) |
| **iOS** | Coming soon |
| **Linux / Mac** | Coming soon |

> *Pro Tip:* Unlocking Pro on Mobile also unlocks Pro features for one linked desktop version!

---

## 🔜 Coming Next

* **Fully Offline with Embedded Models:** The next release will let you run TealKit without any internet connection by loading an embedded model directly from **Hugging Face**. The best-fitting model is recommended based on your device's available hardware — making powerful on-device AI accessible to everyone, no API key required.

---

## 📖 Best Practices

See the [**Best Practices**](https://lschaffer.github.io/tealkit-privacy/guide/#best-practices) section in the User Guide for tips on reducing token costs, using the script wizards effectively, and choosing the right model for each task.

---
**Developed by [L. Schaffer](https://github.com/lschaffer)**