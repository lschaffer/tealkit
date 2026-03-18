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

### 🛠 Built-in Mini MCP Tools
* **Document Intelligence:** Local RAG using **DuckDB**. Index PDFs, Word, and Excel files for instant semantic search across your device.
* **Digital Office:** Deep integration with **Gmail, Google Drive, and Calendar** + universal IMAP/SMTP support.
* **Content & Visualization:** Generate files (TXT, PDF, Excel) and create **Mermaid** diagrams/flowcharts from any data.
* **Web Search & Indexing:** Perform live searches via **SerpApi** or **DuckDuckGo**, and crawl websites for local indexing.
* **Remote Management:** Manage servers via **SSH**, generate and execute **Bash/PowerShell** scripts (Desktop).

### ⚙️ Agentic Workflows & Automation
* **Autonomous Execution:** Schedule **cron-based** tasks that run in the background, even when the app is closed.
* **Task Chaining:** Build complex pipelines with conditional logic (e.g., "If X is found, do Y, then email Z").
* **Multi-Channel Output:** Save results to local storage, or send them via **Email, Slack, or WhatsApp** (with attachments).

---

## 💡 Real-World Examples

| Scenario | The Workflow |
| :--- | :--- |
| **The Daily Researcher** | Every morning at 8 AM, crawl 5 industry news sites, summarize key trends with Gemini, and email a PDF report for yourself. |
| **The Server Guardian** | Every hour, SSH into your server and check disk usage. If it exceeds 90%, send an alert  to your WhatsApp. |
| **The Document Oracle** | Index 1000 pages of local technical manuals. Ask: *"What is the specific torque for the XJ-900 engine?"* and get an instant answer with citations. |
| **The Assistant** | Scan Gmail for flight confirmations, automatically create a Calendar entry, and generate a packing list based on the destination's weather. |

---

## 🔌 Extensibility — Build Any Tool, Connect Any Service

TealKit is an **open agentic platform**: every capability not built-in can be added with your own code or a third-party MCP server — no boilerplate, no backend required.

### Your Own Custom Tools

| Tool Type | Platform | What You Can Do |
| :--- | :--- | :--- |
| **JavaScript** | All (Mobile + Desktop) | Write sandboxed mini MCP tools directly in the app — no server, no install needed. |
| **Bash / Shell Script** | Desktop — Linux & macOS | Generate and run shell scripts locally; stdout/stderr feed straight back into the agent. |
| **PowerShell Script** | Desktop — Windows | Generate and execute PowerShell scripts for full Windows automation from a single prompt. |
| **Python MCP Server** | Desktop — all OS | Build complete MCP servers with the built-in editor, instant reload, and full library access. |

### Connect to Existing MCP Servers

| Method | Platform | How It Works |
| :--- | :--- | :--- |
| **Import from GitHub** | Desktop | One-click install of any Node.js or Python MCP server straight from a GitHub repository URL. |
| **Cloud MCP Servers** | All | Attach hosted servers from Smithery, Glama, or any custom URL in seconds. |

---

## 🔒 Privacy First
**No TealKit Cloud.** Your private data, files, settings, and credentials remain in your device's secure storage. You choose the third-party providers you trust.

---

## 💻 Platforms
* **Android:** Available on Play Store.
* **iOS:** Coming soon.
* **Desktop (Windows, Linux, Mac):** Soon : In Windows Store and downloadable from GitHub. 
    * *Pro Tip:* Unlocking Pro on Desktop also unlocks Pro features for one mobile version!

---
**Developed by [L. Schaffer](https://github.com/lschaffer)**
