#!/usr/bin/env python3
import argparse

from transformers import AutoTokenizer


def main() -> None:
    parser = argparse.ArgumentParser(description="Rewrite tokenizer files with fix_mistral_regex")
    parser.add_argument("--model-path", required=True)
    args = parser.parse_args()

    tok = AutoTokenizer.from_pretrained(args.model_path, use_fast=False, fix_mistral_regex=True)
    tok.save_pretrained(args.model_path)
    print(f"[INFO] Tokenizer rewritten with fixed regex at: {args.model_path}")


if __name__ == "__main__":
    main()
