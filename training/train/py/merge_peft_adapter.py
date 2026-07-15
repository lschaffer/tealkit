#!/usr/bin/env python3
import argparse
import os
import shutil

from peft import PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer


def main() -> None:
    parser = argparse.ArgumentParser(description="Merge PEFT adapter into full HF model")
    parser.add_argument("--base-model", required=True)
    parser.add_argument("--adapter-dir", required=True)
    parser.add_argument("--save-path", required=True)
    args = parser.parse_args()

    if os.path.isdir(args.save_path):
        shutil.rmtree(args.save_path)
    os.makedirs(args.save_path, exist_ok=True)

    base = AutoModelForCausalLM.from_pretrained(
        args.base_model,
        torch_dtype="auto",
        low_cpu_mem_usage=True,
    )
    peft_model = PeftModel.from_pretrained(base, args.adapter_dir)
    merged = peft_model.merge_and_unload()
    merged.save_pretrained(args.save_path, safe_serialization=True)

    tok = AutoTokenizer.from_pretrained(args.base_model, use_fast=False)
    tok.save_pretrained(args.save_path)
    print(f"[INFO] Saved merged HF model to {args.save_path}")


if __name__ == "__main__":
    main()
