# text_tool_call contract

This contract preserves the current training target used by the embedded and llama.cpp-style runtime path.

Canonical assistant target:

- `tool_call: {"name":"<tool_name>","arguments":{...}}`

The current `scripts_training` flow remains backward compatible with this contract and uses it as the default.
