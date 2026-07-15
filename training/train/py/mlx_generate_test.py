#!/usr/bin/env python3
import argparse
import traceback


def main() -> None:
    parser = argparse.ArgumentParser(description="Run MLX generate smoke test")
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--fix-mistral-regex", action="store_true")
    parser.add_argument("--out-file", required=True)
    args = parser.parse_args()

    try:
        from mlx_lm import generate, load
        from transformers import AutoTokenizer

        model, _ = load(args.model_path)
        kwargs = {"use_fast": False}
        if args.fix_mistral_regex:
            kwargs["fix_mistral_regex"] = True
        tok = AutoTokenizer.from_pretrained(args.model_path, **kwargs)

        messages = [{"role": "user", "content": "What is the weather tool? Respond with a valid tool_call JSON."}]
        try:
            prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        except Exception:
            prompt = "[INST] What is the weather tool? Respond with a valid tool_call JSON. [/INST]"

        prompt_token_count = len(tok.encode(prompt))
        if prompt_token_count > 200:
            with open(args.out_file, "w", encoding="utf-8") as f:
                f.write("__MLX_TOKENIZER_INCONCLUSIVE__")
            print(f"[MLX-PY] TOKENIZER_INCONCLUSIVE prompt_tokens={prompt_token_count}")
            return

        response = generate(model, tok, prompt=prompt, max_tokens=128, verbose=True)
        with open(args.out_file, "w", encoding="utf-8") as f:
            f.write(response)
        print("[MLX-PY] generation complete")
        print(f"[MLX-PY] OUTPUT: {response[:200]}")

    except Exception:
        traceback.print_exc()
        with open(args.out_file, "w", encoding="utf-8") as f:
            f.write("")
        raise


if __name__ == "__main__":
    main()
