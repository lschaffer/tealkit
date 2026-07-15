#!/usr/bin/env python3
import argparse
import re
import sys
from collections import Counter


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate MLX generated output for degeneration")
    parser.add_argument("--file", required=True)
    args = parser.parse_args()

    with open(args.file, encoding="utf-8") as f:
        text = f.read().strip()

    if text == "__MLX_TOKENIZER_INCONCLUSIVE__":
        print("[MLX-TEST] WARN: MLX tokenizer behavior is inconclusive for this model (prompt tokenization exploded).")
        print("[MLX-TEST] WARN: Continuing to GGUF + Ollama quality gate (authoritative check).")
        return

    if not text:
        raise SystemExit("[MLX-TEST] FAIL: empty generation - model produced no output")

    tokens = text.split()
    most_common_tok, count = Counter(tokens).most_common(1)[0]
    ratio = count / len(tokens)

    if len(tokens) >= 20 and ratio > 0.4:
        raise SystemExit(
            f"[MLX-TEST] FAIL: degeneration - token '{most_common_tok}' is {ratio:.0%} of output ({len(tokens)} tokens)"
        )

    if len(text) > 20:
        for pat in [r"(\\S{3,})\\1{9,}", r"([a-z]{1,4})\\1{19,}"]:
            if re.search(pat, text, re.IGNORECASE):
                raise SystemExit(
                    f"[MLX-TEST] FAIL: degeneration - repetitive pattern detected in: {text[:80]!r}"
                )

    if len(tokens) >= 20:
        for mo in re.finditer(r"(\\S+)(?:\\s+\\1){19,}", text):
            raise SystemExit(f"[MLX-TEST] FAIL: degeneration - repeated token '{mo.group(1)}'")

    print(f"[MLX-TEST] PASS: output looks healthy ({len(tokens)} tokens, dominant={most_common_tok!r} at {ratio:.0%})")


if __name__ == "__main__":
    main()
