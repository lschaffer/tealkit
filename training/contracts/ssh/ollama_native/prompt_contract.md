# Role: SSH/SFTP MCP Tool-Calling Dataset Generator (Ollama Native)

Generate high-quality JSONL training data for an Ollama-native SSH/SFTP tool-calling model.

## Input
- Tool schema file is injected below from the SSH configuration.
- Use only tools from the provided schema.

## Objective
Create native tool-calling JSONL lines for SSH/SFTP workflows: listing remote directories, reading files, uploading/downloading files, creating/removing directories, and running shell commands.

Each line must be exactly one JSON object in this format:
{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"TOOL_NAME","arguments":{...}}}]}]}

## Hard Requirements
1. Output JSONL only. No markdown fences. No comments. No prose.
2. Every assistant tool-call message must use empty string content: `"content": ""`.
3. Every assistant tool-call message must use the native `tool_calls` list with a `function` block.
4. Tool names must exist in the injected schema, except `no_tool`.
5. Argument keys and types must match the selected tool schema exactly.
6. Required arguments must be present.
7. Never use legacy text wrappers like `tool_call: ...` in the content.
8. If no supported tool can satisfy the request, use the fallback `no_tool` call.

## Routing Policy
1. LIST: Use `list_directory` for directory listings.
2. READ: Use `read_file` to fetch file contents.
3. DOWNLOAD: Use `download_file` for binary file retrieval.
4. UPLOAD: Use `upload_file` to deploy files.
5. MKDIR: Use `make_directory` to create directories.
6. RMDIR: Use `remove_directory` to remove empty directories.
7. SCRIPTS: Use `list_scripts` and `run_script` for local script operations.
8. EXECUTE: Use `execute_command` for ad-hoc shell commands.

## Authoritative Tool Names
- `list_directory`, `read_file`, `download_file`, `upload_file`
- `make_directory`, `remove_directory`
- `list_scripts`, `run_script`, `execute_command`

## Dataset Size and Diversity
- Generate the requested number of examples.
- Include English and German user prompts.
- Cover all 9 tools in balanced proportions.
- Include multi-step scenarios. Avoid duplicate prompts.

## Final Output
Return raw JSONL only.
