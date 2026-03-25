# 🐦‍⬛ TealKit
### The Privacy-First, Infinitely Extensible Agentic AI Platform for Mobile & Desktop

**TealKit** turns your phone and computer into a powerful agentic AI platform with autonomous agents, built-in tools, and unlimited extensibility. Write your own tools in **JavaScript, Python, PowerShell, or Bash** — or connect any MCP server — and let the AI use them autonomously. Provider-independent, fully customizable, and designed for privacy.

[**English User Guide**](https://lschaffer.github.io/tealkit-privacy/guide/) | [**Deutsches Handbuch**](https://lschaffer.github.io/tealkit-privacy/guide/de/) | [**Privacy Policy**](https://github.com/lschaffer/tealkit-privacy)

---

## 🚀 Core Capabilities

### 🤖 AI Playground & Flexibility
* **Provider Independent:** Use leading providers like **Google Gemini, OpenAI GPT-5, Anthropic, and Mistral**.
* **Local Intelligence:** Support for **Ollama** models for 100% offline processing.
* **Full Customization:** Tweak model parameters per task and keep token costs predictable.
* **Chat-to-Task:** Test ideas in the chat interface before promoting them to automated tasks.

### 🛠 Built-in AI Skills
* **Document Intelligence:** Local RAG using **DuckDB**. Index PDFs, Word, and Excel files for instant semantic search across your device.
* **Digital Office:** Deep integration with **Gmail** and **Google Calendar** (free) + **Google Drive** (Pro) + universal IMAP/SMTP support.
* **Content & Visualization:** Generate files (TXT, PDF, Excel) and create **Mermaid** diagrams/flowcharts from any data.
* **Web Search & Indexing:** Perform live searches via **SerpApi** or **DuckDuckGo**, and crawl websites for local indexing.
* **Remote Management:** Manage servers via **SSH** on all platforms. On Desktop, generate and execute **Bash scripts** locally (Linux/macOS) or **PowerShell scripts** (Windows).

### ⚙️ Agentic Workflows & Automation
* **Autonomous Execution:** Schedule **cron-based** tasks that run in the background, even when the app is closed.
* **Task Chaining:** Build complex pipelines with conditional logic (e.g., "If X is found, do Y, then email Z").
* **Multi-Channel Output:** Save results to local storage, or send them via **Email, Slack, or WhatsApp** (with attachments).

---

## 💡 Real-World Examples

### 📱 All Platforms (Mobile + Desktop)

| Scenario | Tools | The Workflow |
| :--- | :---: | :--- |
| **The Daily Researcher** | Web + Email | Every morning at 8 AM, crawl 5 industry news sites, summarize key trends with Gemini, and email a PDF report for yourself. |
| **The Server Guardian** | SSH + WhatsApp | Every hour, SSH into your server and check disk usage. If it exceeds 90%, send an alert to your WhatsApp. |
| **The Document Oracle** | RAG / Documents | Index 1000 pages of local technical manuals. Ask: *"What is the specific torque for the XJ-900 engine?"* and get an instant answer with citations. |
| **The Assistant** | Gmail + Calendar | Scan Gmail for flight confirmations, automatically create a Calendar entry, and generate a packing list based on the destination's weather. |
| **The Cost Analyst** | Gmail + Charts | Search Gmail for all invoices from your mobile provider this year, summarize the actual monthly costs, generate a pie chart from the data, and email you the chart and summary. |
| **The Disk Watcher** | SSH + Email | In the **Shell Script Library**, generate a script named `disku` with prompt *"list disk usage of all mount points in MB, one per line"*. Create a task using the **SSH** tool: *"Call script disku, format the result as a modern styled HTML table with a color-coded status bar"*, output channel **Email**, scheduled **daily at 16:00**. |

### 🖥 Desktop Only

#### 🐙 GitHub Integration

| Scenario | Tools | The Workflow |
| :--- | :---: | :--- |
| **The GitHub Reporter** | GitHub MCP + FTP | Install the Node.js GitHub MCP server from GitHub in TealKit with your access token. Create a task: *"Scan this repository for changes since yesterday, write a formatted summary to a text file, and upload it to an FTP server"*, scheduled **daily at 08:00**. |

#### 🪟 Windows Administration

| Scenario | Tools | The Workflow |
| :--- | :---: | :--- |
| **The Downloads Janitor** | PowerShell + Email | **Step 1 — Script:** In the **PowerShell Script Library**, generate a script named `old_files` with prompt *"Accept a parameter DaysOld. Scan the current user's Downloads folder for files older than DaysOld days. Output each file as: path \| modified date \| size in KB. Sort ascending by modified date."* **Step 2 — Subtask:** Create a subtask named `old_files_alert` with prompt *"You receive a list of old files. Send an email with subject 'Old files in Downloads' and the list formatted as an HTML table."* **Step 3 — Main task:** Create a task using the **PowerShell** tool, prompt *"Call old_files 30. Format the output as a Markdown list."*, enable **Task Chaining**, condition *"list count > 10"*, chained subtask `old_files_alert`, scheduled **daily at 07:00**. |

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

### Connect to Existing MCP Servers

| Method | Platform | How It Works |
| :--- | :--- | :--- |
| **Import from GitHub** | Desktop | One-click install of any Node.js or Python MCP server straight from a GitHub repository URL. |
| **Cloud MCP Servers** | All | Attach hosted servers from Smithery, Glama, or any custom URL in seconds. |

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
| Task chaining / conditional logic | — | ✅ |
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

> *Pro Tip:* Unlocking Pro on Desktop also unlocks Pro features for one linked mobile version!

---
**Developed by [L. Schaffer](https://github.com/lschaffer)**