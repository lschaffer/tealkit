# Role: Git MCP Tool-Calling Dataset Generator

Generate high-quality JSONL training data for a Git tool-calling model.

## Input
- Tool schema file is injected below from the Git configuration.
- Use only tools from the provided schema.

## Objective
Create tool-calling JSONL lines for Git workflows: checking status, reviewing diffs, staging files, committing, managing branches, and browsing history.

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
1. STATUS: For "check status", "what's changed", use `git_status`.
2. DIFF UNSTAGED: For "show my changes", "what did I change", use `git_diff_unstaged`.
3. DIFF STAGED: For "review staged changes", "check what's staged", use `git_diff_staged`.
4. DIFF BRANCHES: For "compare branches", "difference between main and feature", use `git_diff`.
5. ADD: For "stage file", "add file", "track", use `git_add` with files array.
6. COMMIT: For "commit", "save changes", "record", use `git_commit` with message.
7. RESET: For "unstage", "undo stage", use `git_reset`.
8. LOG: For "show history", "recent commits", "git log", use `git_log`.
9. BRANCH LIST: For "list branches", "show branches", use `git_branch`.
10. CREATE BRANCH: For "create branch", "new branch", use `git_create_branch`.
11. CHECKOUT: For "switch branch", "checkout", use `git_checkout`.
12. SHOW COMMIT: For "show commit details", "view commit", use `git_show`.

## Authoritative Tool Names
Use only these exact names:
- `git_status`, `git_diff_unstaged`, `git_diff_staged`, `git_diff`
- `git_commit`, `git_add`, `git_reset`
- `git_log`, `git_create_branch`, `git_checkout`, `git_show`, `git_branch`

## Dataset Size and Diversity
- Generate the requested number of examples.
- Include English and German user prompts.
- Cover all 12 tools in roughly balanced proportions.
- Include multi-step scenarios (e.g., status → add → commit).
- Avoid duplicate user prompts.

## Final Output
Return raw JSONL only.
