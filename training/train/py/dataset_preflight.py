#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


def count_non_empty_lines(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip())


def prompts(path: Path) -> list[str]:
    vals: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        for msg in obj.get("messages", []):
            if isinstance(msg, dict) and msg.get("role") == "user":
                vals.append(str(msg.get("content", "")).strip())
                break
    return vals


def pattern_hits(path: Path) -> tuple[int, int]:
    ipi_hits = 0
    rep_hits = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        lo = line.lower()
        if re.search(r"(ipi){3,}", lo):
            ipi_hits += 1
        if re.search(r"(.)\\1{10,}", line):
            rep_hits += 1
    return ipi_hits, rep_hits


def iter_message_rows(path: Path):
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        messages = obj.get("messages", [])
        if isinstance(messages, list):
            yield messages


def _fallback_render_messages(messages: list[dict]) -> str:
    parts: list[str] = []
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role", "")).strip()
        content = str(msg.get("content", "")).strip()
        if role or content:
            parts.append(f"{role}: {content}")
    return "\n".join(parts)


def token_length_stats(path: Path, tokenizer_model: str, max_seq_length: int) -> tuple[int, int, int]:
    try:
        from transformers import AutoTokenizer
    except Exception as exc:
        raise SystemExit(
            "[ERROR] transformers is required for token-length preflight. "
            "Install it or set ALLOW_SEQUENCE_TRUNCATION=1 to bypass this check."
        ) from exc

    tokenizer = AutoTokenizer.from_pretrained(tokenizer_model, trust_remote_code=True)
    over_limit = 0
    max_seen = 0
    row_count = 0

    for messages in iter_message_rows(path):
        row_count += 1
        token_ids = None
        try:
            token_ids = tokenizer.apply_chat_template(
                messages,
                tokenize=True,
                add_generation_prompt=False,
            )
        except Exception:
            rendered = _fallback_render_messages(messages)
            token_ids = tokenizer(rendered, add_special_tokens=True).get("input_ids", [])

        length = len(token_ids)
        if length > max_seen:
            max_seen = length
        if length > max_seq_length:
            over_limit += 1

    return row_count, max_seen, over_limit


def main() -> None:
    parser = argparse.ArgumentParser(description="Run dataset preflight checks")
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--min-train-lines", type=int, default=200)
    parser.add_argument("--allow-overlap", action="store_true")
    parser.add_argument("--tokenizer-model")
    parser.add_argument("--max-seq-length", type=int)
    parser.add_argument("--allow-truncation", action="store_true")
    args = parser.parse_args()

    train_path = Path(args.train)
    valid_path = Path(args.valid)

    if not train_path.exists():
        raise SystemExit(f"[ERROR] Training file not found: {train_path}")
    if not valid_path.exists():
        raise SystemExit(f"[ERROR] Validation file not found: {valid_path}")

    train_lines = count_non_empty_lines(train_path)
    valid_lines = count_non_empty_lines(valid_path)
    print(f"[INFO] Training file: {train_path} ({train_lines} lines)")
    print(f"[INFO] Validation file: {valid_path} ({valid_lines} lines)")

    if train_lines < args.min_train_lines:
        raise SystemExit(
            f"[ERROR] Training data too small: {train_lines} < MIN_TRAIN_LINES={args.min_train_lines}"
        )

    tp = set(prompts(train_path))
    vp = set(prompts(valid_path))
    overlap = len(tp.intersection(vp))
    ipi_t, rep_t = pattern_hits(train_path)
    ipi_v, rep_v = pattern_hits(valid_path)

    print(f"[INFO] Preflight: train/valid prompt overlap={overlap}")
    print(f"[INFO] Preflight: train pattern hits ipi={ipi_t}, repeated-char={rep_t}")
    print(f"[INFO] Preflight: valid pattern hits ipi={ipi_v}, repeated-char={rep_v}")

    if (ipi_t + rep_t + ipi_v + rep_v) > 0:
        raise SystemExit("[ERROR] Dataset contains suspicious repetition patterns. Abort training.")
    if overlap > 0 and not args.allow_overlap:
        raise SystemExit(
            "[ERROR] Train/valid prompt overlap detected. Use split data or set ALLOW_TRAIN_VALID_OVERLAP=1."
        )

    if args.tokenizer_model and args.max_seq_length:
        train_rows, train_max_len, train_over = token_length_stats(
            train_path,
            tokenizer_model=args.tokenizer_model,
            max_seq_length=args.max_seq_length,
        )
        valid_rows, valid_max_len, valid_over = token_length_stats(
            valid_path,
            tokenizer_model=args.tokenizer_model,
            max_seq_length=args.max_seq_length,
        )
        print(
            f"[INFO] Token-length preflight: train rows={train_rows}, max={train_max_len}, over_limit={train_over}"
        )
        print(
            f"[INFO] Token-length preflight: valid rows={valid_rows}, max={valid_max_len}, over_limit={valid_over}"
        )
        if (train_over + valid_over) > 0 and not args.allow_truncation:
            raise SystemExit(
                "[ERROR] Prepared chat rows exceed TRAIN_MAX_SEQ_LENGTH. "
                "Increase TRAIN_MAX_SEQ_LENGTH or set ALLOW_SEQUENCE_TRUNCATION=1 to continue."
            )


if __name__ == "__main__":
    main()
