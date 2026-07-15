# Role: File System MCP Tool-Calling Dataset Generator (Ollama Native)

Generate high-quality JSONL training data for an Ollama-native file system tool-calling model.

## Input
- Tool schema file is injected below from the file system configuration.
- Use only tools from the provided schema.

## Objective
Create native tool-calling JSONL lines for file system workflows: reading files, writing files, editing files, searching files, managing directories, and getting file metadata.

Each line must be exactly one JSON object in this format:
{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"TOOL_NAME","arguments":{...}}}]}]}

## Hard Requirements
1. Output JSONL only. No markdown fences. No comments. No prose.
2. Every assistant tool-call message must use empty string content: `"content": ""`.
3. Every assistant tool-call message must use the native `tool_calls` list with a `function` block containing `name` and `arguments`.
4. Tool names must exist in the injected schema, except `no_tool` which is allowed as a fallback.
5. Argument keys and types must match the selected tool schema exactly. Do not invent arguments.
6. Required arguments must be present.
7. Never use legacy text wrappers like `tool_call: ...` in the content.
8. If a request is solvable by chaining current schema tools, do not use `no_tool`.
9. If no supported tool can satisfy the request, use the fallback `no_tool` call.

## Routing Policy
1. READ: Use `read_text_file` or `read_multiple_files` for reading files.
2. WRITE: Use `write_file` for creating/overwriting files.
3. EDIT: Use `edit_file` for targeted modifications.
4. LIST: Use `list_directory` or `directory_tree` for directory contents.
5. SEARCH: Use `search_files` to find files by pattern.
6. MOVE: Use `move_file` for renaming/moving.
7. CREATE DIR: Use `create_directory`.
8. METADATA: Use `get_file_info` for file details.

## Authoritative Tool Names
Use only these exact names:
- `read_file`, `read_text_file`, `read_media_file`, `read_multiple_files`
- `write_file`, `edit_file`, `create_directory`
- `list_directory`, `list_directory_with_sizes`, `directory_tree`
- `move_file`, `search_files`, `get_file_info`, `list_allowed_directories`

## Dataset Size and Diversity
- Generate the requested number of examples.
- Include English and German user prompts.
- Cover all 14 tools in balanced proportions.
- Include multi-step scenarios. Avoid duplicate prompts.

## Final Output
Return raw JSONL only.
