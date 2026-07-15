# Role: File System MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for a file system tool-calling model.

## Input
- Tool schema file is injected below from the file system configuration.
- Use only tools from the provided schema.

## Objective
Create tool-calling JSONL lines for file system workflows: reading files, writing files, editing files, searching files, managing directories, and getting file metadata.

Each line must be exactly one JSON object in this format:
{"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"tool_call: {\"name\":\"TOOL_NAME\",\"arguments\":{...}}"}]}

## Hard Requirements
1. Output JSONL only. No markdown fences. No comments. No prose.
2. Every assistant tool-call message must use the legacy text wrapper format: `tool_call: {"name":"<tool_name>","arguments":{...}}`
3. Tool names must exist in the injected schema, except `no_tool` which is allowed as a fallback.
4. Argument keys and types must match the selected tool schema exactly. Do not invent arguments.
5. Required arguments must be present.
6. If a request is solvable by chaining current schema tools, do not use `no_tool`.
7. If no supported tool can satisfy the request, use the fallback `no_tool` call:
   `"content": "tool_call: {\"name\":\"no_tool\",\"arguments\":{\"reason\":\"short explanation\"}}"`

## Parameter Constraints
- `path` is required for all file/directory operations (string, must be within allowed directories).
- `paths` for `read_multiple_files` is required (array of strings).
- `pattern` for `search_files` uses glob syntax (string).
- `edits` for `edit_file` is an array of objects with `oldText` and `newText` fields.
- `content` for `write_file` is a string.
- `dryRun` for `edit_file` is an optional boolean (default false).
- `sortBy` for `list_directory_with_sizes` is optional: `"name"` or `"size"`.

## Routing Policy
1. READ FILE: For "read file", "show me the content of", "open file", use `read_text_file`.
2. READ MULTIPLE: For "read all these files", "show me multiple files", use `read_multiple_files`.
3. READ MEDIA: For images or audio files, use `read_media_file`.
4. WRITE: For "create file", "write to file", "save content", use `write_file`.
5. EDIT: For "change line X", "update the code", "modify the file", use `edit_file`.
6. LIST DIR: For "list files", "what's in this directory", "show folder", use `list_directory`.
7. DIRECTORY TREE: For "show me the full structure", "recursive listing", use `directory_tree`.
8. SEARCH: For "find files", "search for", "locate", use `search_files`.
9. FILE INFO: For "file details", "metadata", "file size", use `get_file_info`.
10. MOVE: For "rename", "move file", "relocate", use `move_file`.
11. CREATE DIR: For "create folder", "make directory", "mkdir", use `create_directory`.
12. CHECK ALLOWED: For "what directories can you access?", use `list_allowed_directories`.

## Authoritative Tool Names
Use only these exact names:
- `read_file`
- `read_text_file`
- `read_media_file`
- `read_multiple_files`
- `write_file`
- `edit_file`
- `create_directory`
- `list_directory`
- `list_directory_with_sizes`
- `directory_tree`
- `move_file`
- `search_files`
- `get_file_info`
- `list_allowed_directories`

Never invent near-miss names.

## Exact Output Examples
Valid examples:
- `{"messages": [{"role": "user", "content": "Show me the contents of /home/user/config.json"}, {"role": "assistant", "content": "tool_call: {\"name\":\"read_text_file\",\"arguments\":{\"path\":\"/home/user/config.json\"}}"}]}`
- `{"messages": [{"role": "user", "content": "List all Python files in the project directory"}, {"role": "assistant", "content": "tool_call: {\"name\":\"search_files\",\"arguments\":{\"path\":\"/home/user/project\",\"pattern\":\"**/*.py\"}}"}]}`
- `{"messages": [{"role": "user", "content": "Create a file called hello.txt with the content Hello World"}, {"role": "assistant", "content": "tool_call: {\"name\":\"write_file\",\"arguments\":{\"path\":\"/home/user/hello.txt\",\"content\":\"Hello World\"}}"}]}`

## Dataset Size and Diversity
- Generate the requested number of examples per batch.
- Include English and German user prompts.
- Mix short, noisy, typo-prone, and conversational prompts.
- Cover all 14 tools in roughly balanced proportions.
- Include multi-step scenarios (e.g., list directory → read file → edit file).
- Avoid duplicate user prompts.

## Output Quality Checks Before Finalizing
- Every line parses as JSON.
- No unknown tool names. No invalid keys.
- Required arguments present. Types are valid.

## Final Output
Return raw JSONL only.
