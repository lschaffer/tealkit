#!/usr/bin/env python3
import argparse
import sys

from safetensors import safe_open
from transformers import AutoConfig


def main() -> None:
    parser = argparse.ArgumentParser(description="Check adapter compatibility with base model")
    parser.add_argument("--adapter-file", required=True)
    parser.add_argument("--model-id", required=True)
    args = parser.parse_args()

    cfg = AutoConfig.from_pretrained(args.model_id)
    expected_hidden = getattr(cfg, "hidden_size", None)
    if expected_hidden is None and getattr(cfg, "text_config", None) is not None:
        expected_hidden = getattr(cfg.text_config, "hidden_size", None)

    if expected_hidden is None:
        print("cannot-determine-model-hidden-size")
        sys.exit(2)

    with safe_open(args.adapter_file, framework="np") as f:
        lora_a_keys = [k for k in f.keys() if k.endswith("lora_a")]
        if not lora_a_keys:
            print("no-lora-a-weights")
            sys.exit(3)
        adapter_hidden = f.get_tensor(lora_a_keys[0]).shape[0]

    if int(adapter_hidden) != int(expected_hidden):
        print(f"mismatch:{adapter_hidden}:{expected_hidden}")
        sys.exit(10)

    print("ok")


if __name__ == "__main__":
    main()
