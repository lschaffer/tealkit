#!/usr/bin/env python3
import argparse
import json


def main() -> None:
    parser = argparse.ArgumentParser(description="Patch tokenizer_config.json with fix_mistral_regex=true")
    parser.add_argument("--file", required=True)
    args = parser.parse_args()

    with open(args.file, encoding="utf-8") as f:
        cfg = json.load(f)

    if not cfg.get("fix_mistral_regex"):
        cfg["fix_mistral_regex"] = True
        with open(args.file, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        print(f"[INFO] Patched {args.file}")
    else:
        print(f"[INFO] Already patched: {args.file}")


if __name__ == "__main__":
    main()
