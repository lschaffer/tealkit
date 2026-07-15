# 🔒 Security & Privacy

TealKit is designed with a **privacy-first, zero-telemetry** architecture. No cloud, no tracking, no data leaving your device unless you explicitly instruct it to.

---

## 🔑 Credential Storage

| Platform | Storage Mechanism |
| :--- | :--- |
| **Android** | [Android Keystore](https://developer.android.com/privacy-and-security/keystore) system via `flutter_secure_storage` — hardware-backed encryption when available |
| **iOS** | [iOS Keychain](https://developer.apple.com/documentation/security/keychain_services) via `flutter_secure_storage` — hardware-backed Secure Enclave storage |
| **Windows (Client)** | [Windows Credential Manager](https://learn.microsoft.com/en-us/windows/win32/secauthn/credentials-management) via `flutter_secure_storage` |
| **Windows / Linux / macOS (Server)** | Encrypted DuckDB database — AES-256-GCM encrypted fields with a device-generated key stored in the platform keychain |
| **macOS (Client)** | [macOS Keychain](https://developer.apple.com/documentation/security/keychain_services) via `flutter_secure_storage` |
| **Linux (Client)** | [Secret Service (D-Bus)](https://specifications.freedesktop.org/secret-service/latest/) via `flutter_secure_storage` |

All API keys, OAuth tokens, IMAP/SMTP credentials, SSH keys, and service passwords are encrypted at rest using **AES-256-GCM** via `CredentialCipher`. The encryption key itself is generated once per device and stored exclusively in the platform's native secure vault — never in the app's own data directory.

---

## 🕵️ What Leaves Your Device

- **Nothing is sent automatically.** TealKit does not phone home, collect telemetry, or transmit any credentials or secrets to any server.
- **LLM API calls** contain only the prompts and tool definitions you explicitly configure — your API key is injected by the app locally and never exposed to the model provider beyond what is required to authenticate the request.
- **Credentials stay local.** No password, API key, OAuth token, or SSH private key is ever sent to any LLM provider, MCP registry, or third-party service. The only exception is data you **deliberately type into the prompt** (e.g., asking the model to use a specific key as part of a workflow).

---

## 🖧 SSH Tool — Authentication Isolation

The built-in SSH tool (see the [User Guide Tools Reference](https://lschaffer.github.io/tealkit/guide/#tools-reference)) opens SSH connections **entirely within the app process** using the [`dartssh2`](https://pub.dev/packages/dartssh2) library. Credentials (password or private key) are:

1. Loaded from encrypted storage or per-task parameters.
2. Used **locally** by the SSH client to authenticate the TCP connection.
3. **Never passed to the LLM model** — the model only receives the **stdout/stderr output** of the remote command.

This means the AI agent can run shell scripts on your remote servers without ever revealing authentication secrets to the language model.

---

## 🛡️ Security Best Practices

### 🔌 MCP Servers — Trust & Credential Hygiene

When registering third-party MCP servers, be cautious:

- **Do not** register an MCP server that asks for credentials or secrets unrelated to that server's function. A legitimate weather MCP server should never ask for your Gmail password or database connection string.
- **Audit init parameters** before saving a new MCP server — if a parameter looks suspicious or excessive for the tool's purpose, investigate the server's source code first.
- **Prefer read-only tokens** when an MCP server offers scoped access. For example, use a read-only GitHub token if the server only needs to list repositories.

### 🧑‍💻 SSH — Least Privilege Principle

- **Avoid using `root`** as the SSH username unless the task absolutely requires administrative access. Create a dedicated, limited-privilege user account on the remote server for agent-driven commands.
- **Use key-based authentication** (Ed25519 or RSA) instead of passwords where possible — keys can be scoped and revoked individually.
- **Restrict commands** where feasible: consider what a remote user can run via `/etc/sudoers` restrictions, `authorized_keys` `command=` directives, or a restricted shell (`rbash`).

### 🤖 Agent Automation — Know What You Automate

Autonomous agents are powerful. Before enabling scheduled, unattended execution, ask yourself:

- **Would I be comfortable if this action ran at 3 AM without my review?** If not, schedule it during office hours or add a human-in-the-loop step.
- **Does this agent perform financial transactions?** Avoid prompts like *"buy the cheapest ticket to …"* or *"transfer funds to …"* without explicit confirmation gates. Agents cannot exercise judgement the way a human can.
- **Does this agent modify or delete data?** Consider running destructive operations in a staging environment first, or chaining an email notification step so you are alerted when the action completes.
- **Can this agent be triggered accidentally?** Review the trigger conditions (schedules, chaining rules, conditions) to prevent unintended cascading execution.

### 💾 Vault & Backups

- Use the built-in **Vault** feature (export to an AES-256 encrypted `.tkv` file) to back up your configuration — including all credentials — to a secure location. Store the backup file offline or in a trusted password manager.
- When restoring a vault on a new device, verify the import was successful by checking that all configured services appear in the Data Sources settings.

---

## 📋 Summary Checklist

| Area | Recommendation |
| :--- | :--- |
| ✅ **MCP Servers** | Only register servers that request credentials relevant to their function |
| ✅ **SSH** | Use non-root users and key-based authentication |
| ✅ **Automation** | Limit autonomous agents to non-destructive, reviewable actions |
| ✅ **Financial Actions** | Never automate purchases or transfers without human confirmation |
| ✅ **Vault** | Regularly export encrypted backups of all credentials |
| ✅ **API Keys** | Rotate keys periodically and revoke any that are no longer needed |
