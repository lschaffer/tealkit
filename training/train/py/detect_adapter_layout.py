#!/usr/bin/env python3
import argparse
import os
import sys


def detect_layout(path: str) -> str:
    if os.path.isfile(os.path.join(path, "adapters.safetensors")):
        return "mlx"
    if os.path.isfile(os.path.join(path, "adapter_model.safetensors")) and os.path.isfile(
        os.path.join(path, "adapter_config.json")
    ):
        return "peft"
    return "unknown"


def main() -> None:
    parser = argparse.ArgumentParser(description="Detect adapter layout in directory")
    parser.add_argument("--path", required=True)
    args = parser.parse_args()

    layout = detect_layout(args.path)
    print(layout)
    if layout == "unknown":
        sys.exit(1)


if __name__ == "__main__":
    main()
