#!/usr/bin/env python3
"""LoRA fine-tuning using Unsloth for MCP tool-call data.

Supports the same model presets as train_mcp.sh (phi4, qwen2_5_3b).
Intended for CUDA-capable machines (Windows / Linux with NVIDIA GPU).
For Apple Silicon use train_mcp.sh (MLX backend).

Usage:
    python train_lora.py
    python train_lora.py --preset qwen2_5_3b
    python train_lora.py --export-gguf
    python train_lora.py --export-gguf --quant q5_k_m
    python train_lora.py --push-gguf your-username/phi4mini-tealkit

Requirements (install once):
    pip install unsloth trl datasets huggingface_hub
    # or the Colab-style no-deps install:
    # pip install --no-deps unsloth_zoo bitsandbytes accelerate peft trl triton unsloth
"""

import argparse
from pathlib import Path

# ---------------------------------------------------------------------------
# Model presets — mirror apply_model_preset() in train_mcp.sh
# ---------------------------------------------------------------------------

PRESETS = {
    "phi4": {
        "model_name":       "unsloth/Phi-4-mini-instruct-bnb-4bit",
        "chat_template":    "phi-4",
        # Markers are auto-detected from the formatted data (see detect_markers below).
        # phi-4 uses <|im_sep|> or \n depending on Unsloth version; None triggers auto-detect.
        "instruction_part": None,
        "response_part":    None,
        "ollama_name":      "phi4mini-tealkit",
    },
    "qwen2_5_3b": {
        "model_name":       "unsloth/Qwen2.5-3B-Instruct-bnb-4bit",
        "chat_template":    "qwen-2.5",
        "instruction_part": "<|im_start|>user\n",
        "response_part":    "<|im_start|>assistant\n",
        "ollama_name":      "qwen25-3b-tealkit",
    },
}

DEFAULT_PRESET = "phi4"

SCRIPT_DIR     = Path(__file__).parent
DATA_DIR       = SCRIPT_DIR / "mcp_data" / "weather_sensors"
MAX_SEQ_LENGTH = 1024
LORA_RANK      = 16
TRAIN_EPOCHS   = 1
BATCH_SIZE     = 2
GRAD_ACCUM     = 4           # effective batch = BATCH_SIZE * GRAD_ACCUM
LEARNING_RATE  = 2e-4
SEED           = 3407

SYSTEM_PROMPT = (
    "You are a specialized MCP Agent. "
    "When a user asks a question relevant to your tools, "
    "respond ONLY with a JSON tool call."
)


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------

def run_training(preset: dict, adapter_path: Path, train_path: Path, valid_path: Path) -> None:
    try:
        from unsloth import FastLanguageModel
        from unsloth.chat_templates import get_chat_template, train_on_responses_only
        from trl import SFTTrainer, SFTConfig
        from transformers import DataCollatorForSeq2Seq
        from datasets import load_dataset
    except ImportError as e:
        raise SystemExit(
            f"Missing dependency: {e}\n"
            "Install with: pip install unsloth trl datasets"
        )

    print(f"Loading model : {preset['model_name']}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=preset["model_name"],
        max_seq_length=MAX_SEQ_LENGTH,
        load_in_4bit=True,
    )

    model = FastLanguageModel.get_peft_model(
        model,
        r=LORA_RANK,
        target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
        lora_alpha=LORA_RANK,
        lora_dropout=0,             # 0 is optimised by Unsloth
        bias="none",
        use_gradient_checkpointing="unsloth",   # ~30 % less VRAM vs True
        random_state=SEED,
    )
    model.print_trainable_parameters()

    tokenizer = get_chat_template(tokenizer, chat_template=preset["chat_template"])

    def format_example(examples):
        texts = []
        for msgs in examples["messages"]:
            if not msgs or msgs[0].get("role") != "system":
                msgs = [{"role": "system", "content": SYSTEM_PROMPT}] + list(msgs)
            texts.append(
                tokenizer.apply_chat_template(
                    msgs, tokenize=False, add_generation_prompt=False
                )
            )
        return {"text": texts}

    print(f"Loading dataset: train={train_path}  valid={valid_path}")
    dataset = load_dataset(
        "json",
        data_files={"train": str(train_path), "validation": str(valid_path)},
    )
    dataset = dataset.map(format_example, batched=True)
    print(f"Train: {len(dataset['train'])}  Valid: {len(dataset['validation'])}")
    sample_text = dataset["train"][0]["text"]
    print("\nSample (first 400 chars):")
    print(repr(sample_text[:400]))

    # Auto-detect markers when preset doesn't hard-code them (e.g. phi-4)
    instruction_part = preset["instruction_part"]
    response_part    = preset["response_part"]
    if instruction_part is None:
        if "<|im_sep|>" in sample_text:
            instruction_part = "<|im_start|>user<|im_sep|>"
            response_part    = "<|im_start|>assistant<|im_sep|>"
        elif "<|im_start|>user\n" in sample_text:
            instruction_part = "<|im_start|>user\n"
            response_part    = "<|im_start|>assistant\n"
        elif "[INST]" in sample_text:
            instruction_part = "[INST] "
            response_part    = " [/INST]"
        else:
            raise ValueError(
                "Cannot auto-detect chat markers. Inspect the sample text above "
                "and set instruction_part/response_part in the preset manually."
            )
    print(f"Markers → instruction={repr(instruction_part)}  response={repr(response_part)}")

    adapter_path.mkdir(parents=True, exist_ok=True)

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset["train"],
        eval_dataset=dataset["validation"],
        dataset_text_field="text",
        max_seq_length=MAX_SEQ_LENGTH,
        data_collator=DataCollatorForSeq2Seq(tokenizer=tokenizer),
        packing=False,
        args=SFTConfig(
            per_device_train_batch_size=BATCH_SIZE,
            gradient_accumulation_steps=GRAD_ACCUM,
            warmup_steps=5,
            num_train_epochs=TRAIN_EPOCHS,
            learning_rate=LEARNING_RATE,
            logging_steps=10,
            eval_strategy="epoch",
            optim="adamw_8bit",
            weight_decay=0.01,
            lr_scheduler_type="linear",
            seed=SEED,
            output_dir=str(adapter_path),
            report_to="none",
        ),
    )

    # Train only on assistant responses — ignores loss on user/system turns
    trainer = train_on_responses_only(
        trainer,
        instruction_part=instruction_part,
        response_part=response_part,
    )

    print("Starting training...")
    trainer.train()

    print(f"Saving adapters to: {adapter_path}")
    model.save_pretrained(str(adapter_path))
    tokenizer.save_pretrained(str(adapter_path))
    print("Training complete.")


# ---------------------------------------------------------------------------
# GGUF export
# ---------------------------------------------------------------------------

def export_gguf(adapter_path: Path, fused_path: Path, quant: str, ollama_name: str) -> None:
    try:
        from unsloth import FastLanguageModel
    except ImportError as e:
        raise SystemExit(f"Missing dependency: {e}")

    if not adapter_path.exists():
        raise SystemExit(
            f"Adapter not found: {adapter_path}\n"
            "Train first (omit --export-gguf)."
        )

    print(f"Loading adapter from : {adapter_path}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=str(adapter_path),
        max_seq_length=MAX_SEQ_LENGTH,
        load_in_4bit=False,   # fp16 avoids 4-bit tensor-shape mismatch during LoRA merge
        dtype=None,           # auto (fp16 on GPU, fp32 on CPU)
    )

    fused_path.mkdir(parents=True, exist_ok=True)
    print(f"Exporting GGUF ({quant}) to: {fused_path}")
    model.save_pretrained_gguf(str(fused_path), tokenizer, quantization_method=quant)

    # Write Ollama Modelfile
    modelfile = fused_path / "Modelfile"
    modelfile.write_text(
        f'FROM .\n'
        f'SYSTEM "{SYSTEM_PROMPT}"\n'
        f'SYSTEM "Output format must be exactly: tool_call: {{\\"name\\": \\"<tool_name>\\", \\"arguments\\": {{ ... }}}}. No prose."\n'
        f'PARAMETER num_ctx 1024\n',
        encoding="utf-8",
    )

    print("\nGenerated files:")
    for f in sorted(fused_path.iterdir()):
        if f.is_file():
            size_mb = f.stat().st_size / (1024 ** 2)
            print(f"  {f.name}  ({size_mb:.0f} MB)")

    print(f"\nRegister with Ollama:")
    print(f"  ollama create {ollama_name} -f {modelfile}")


# ---------------------------------------------------------------------------
# Push GGUF to Hugging Face
# ---------------------------------------------------------------------------

def push_gguf(adapter_path: Path, fused_path: Path, hf_repo: str, quant: str) -> None:
    try:
        from unsloth import FastLanguageModel
    except ImportError as e:
        raise SystemExit(f"Missing dependency: {e}")

    if not adapter_path.exists():
        raise SystemExit(
            f"Adapter not found: {adapter_path}\n"
            "Train first, or run --export-gguf to create the fused model."
        )

    print(f"Loading adapter from : {adapter_path}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=str(adapter_path),
        max_seq_length=MAX_SEQ_LENGTH,
        load_in_4bit=True,
    )

    print(f"Pushing GGUF ({quant}) to HF repo: {hf_repo}")
    model.push_to_hub_gguf(hf_repo, tokenizer, quantization_method=quant, token=True)
    print("Done.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Unsloth LoRA fine-tune for MCP tool-calling.\n"
            "Requires CUDA (NVIDIA GPU). For Apple Silicon use train_mcp.sh (MLX)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--preset", default=DEFAULT_PRESET, choices=list(PRESETS),
        help=f"Model preset matching train_mcp.sh presets (default: {DEFAULT_PRESET})",
    )
    parser.add_argument(
        "--train", default=None,
        help="Training JSONL (default: servers/weathersensorsmcp/datasets/text_tool_call/train_split.jsonl)",
    )
    parser.add_argument(
        "--valid", default=None,
        help="Validation JSONL (default: servers/weathersensorsmcp/datasets/text_tool_call/valid_split.jsonl)",
    )
    parser.add_argument(
        "--export-gguf", action="store_true",
        help="Export trained adapters to GGUF (skips training)",
    )
    parser.add_argument(
        "--push-gguf", metavar="OWNER/REPO",
        help="Push GGUF to Hugging Face repo (skips training)",
    )
    parser.add_argument(
        "--quant", default="q4_k_m",
        choices=["q4_k_m", "q5_k_m", "q8_0", "f16"],
        help="GGUF quantisation method (default: q4_k_m)",
    )
    args = parser.parse_args()

    preset       = PRESETS[args.preset]
    adapter_path = SCRIPT_DIR / f"mcp_adapters_{args.preset}"
    fused_path   = SCRIPT_DIR / f"mcp_fused_model_{args.preset}"

    print(f"Preset      : {args.preset}")
    print(f"Model       : {preset['model_name']}")
    print(f"Chat tmpl   : {preset['chat_template']}")
    print(f"Adapter dir : {adapter_path}")
    print(f"Fused dir   : {fused_path}")

    if args.push_gguf:
        push_gguf(adapter_path, fused_path, args.push_gguf, args.quant)
        return

    if args.export_gguf:
        export_gguf(adapter_path, fused_path, args.quant, preset["ollama_name"])
        return

    # Training
    default_train = DATA_DIR / "train_split.jsonl"
    default_valid = DATA_DIR / "valid_split.jsonl"

    train_path = Path(args.train) if args.train else (default_train if default_train.exists() else DATA_DIR / "train.jsonl")
    valid_path = Path(args.valid) if args.valid else (default_valid if default_valid.exists() else DATA_DIR / "valid.jsonl")

    if not train_path.exists():
        raise SystemExit(
            f"Training file not found: {train_path}\n"
            "Generate it first: python scripts_training/train.py --split"
        )
    if not valid_path.exists():
        raise SystemExit(f"Validation file not found: {valid_path}")

    run_training(preset, adapter_path, train_path, valid_path)


if __name__ == "__main__":
    main()
