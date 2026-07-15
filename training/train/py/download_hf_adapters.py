#!/usr/bin/env python3
import argparse
import os
import shutil

from huggingface_hub import snapshot_download


def detect_layout(path: str) -> str:
    if os.path.isfile(os.path.join(path, "adapters.safetensors")):
        return "mlx"
    if os.path.isfile(os.path.join(path, "adapter_model.safetensors")) and os.path.isfile(
        os.path.join(path, "adapter_config.json")
    ):
        return "peft"
    return "unknown"


def copy_tree_contents(src: str, dest: str) -> int:
    copied = 0
    for name in os.listdir(src):
        src_path = os.path.join(src, name)
        dst_path = os.path.join(dest, name)
        if os.path.isdir(src_path):
            if os.path.exists(dst_path):
                shutil.rmtree(dst_path)
            shutil.copytree(src_path, dst_path)
        else:
            shutil.copy2(src_path, dst_path)
        copied += 1
    return copied


def main() -> None:
    parser = argparse.ArgumentParser(description="Download adapter folder from Hugging Face")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--subdir", default="adapters")
    parser.add_argument("--dest", required=True)
    args = parser.parse_args()

    root = snapshot_download(repo_id=args.repo, repo_type="model")
    subdir = args.subdir.strip("/")
    src = os.path.join(root, subdir) if subdir else root

    if not os.path.isdir(src):
        raise SystemExit(f"[ERROR] Adapter subdir not found in repo: {src}")

    os.makedirs(args.dest, exist_ok=True)
    copied = copy_tree_contents(src, args.dest)
    layout = detect_layout(args.dest)

    if layout == "unknown":
        raise SystemExit(
            "[ERROR] Unsupported adapter format. Expected MLX (adapters.safetensors) "
            "or PEFT (adapter_model.safetensors + adapter_config.json)."
        )

    print(f"[INFO] Copied {copied} adapter files from {src} to {args.dest}")
    print(f"[INFO] Adapter layout: {layout}")


if __name__ == "__main__":
    main()
