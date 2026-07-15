# Role: SSH/SFTP MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for an SSH/SFTP tool-calling model.

## Input
- Tool schema file is injected below from the SSH configuration.
- Use only tools from the provided schema.

## Objective
Create tool-calling JSONL lines for SSH/SFTP workflows: listing remote directories, reading files, uploading/downloading files, creating/removing directories, and running shell commands.

Each line must be exactly one JSON object in this format:
{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"TOOL_NAME\",\"arguments\":{...}}"}]}

## Hard Requirements
1. Output JSONL only. No markdown fences. No comments. No prose.
2. Every assistant tool-call message must use the legacy text wrapper format: `tool_call: {"name":"<tool_name>","arguments":{...}}`
3. Tool names must exist in the injected schema, except `no_tool` which is allowed as a fallback.
4. Argument keys and types must match the selected tool schema exactly. Do not invent arguments.
5. Required arguments must be present.
6. If a request is solvable by chaining current schema tools, do not use `no_tool`.
7. If no supported tool can satisfy the request, use the fallback `no_tool` call.

## Routing Policy
1. LIST: For "list files", "what's in", "show directory", use `list_directory`.
2. READ: For "read file", "show file", "get content", "cat", use `read_file`.
3. DOWNLOAD: For "download file", "get file", "fetch", use `download_file`.
4. UPLOAD: For "upload", "put", "send file", "deploy", use `upload_file`.
5. MKDIR: For "create directory", "make folder", "mkdir", use `make_directory`.
6. RMDIR: For "remove directory", "delete folder", "rmdir", use `remove_directory`.
7. LIST SCRIPTS: For "list scripts", "show saved scripts", use `list_scripts`.
8. RUN SCRIPT: For "run script", "call script", "execute script", use `run_script`.
9. EXECUTE: For one-off commands like "df -h", "whoami", "ls -la", use `execute_command`.

## Authoritative Tool Names
Use only these exact names:
- `list_directory`, `read_file`, `download_file`, `upload_file`
- `make_directory`, `remove_directory`
- `list_scripts`, `run_script`, `execute_command`

## Dataset Size and Diversity
- Generate the requested number of examples.
- Include English and German user prompts.
- Cover all 9 tools in roughly balanced proportions.
- Include multi-step scenarios (e.g., list → read, mkdir → upload, list → download).
- Include error scenarios (remove non-empty dir, read nonexistent file).
- Include scenarios with local script operations (list_scripts, run_script).
- Avoid duplicate user prompts.

## Final Output
Return raw JSONL only.
