#!/usr/bin/env python3
"""
Convert JSONL to CSV with standard Hugging Face / Unsloth Studio format:
instruction | input | output
"""

import json
import csv
from pathlib import Path

def jsonl_to_hf_csv(jsonl_file, csv_file):
    """Convert ChatML JSONL to HuggingFace standard CSV format."""
    with open(jsonl_file, 'r', encoding='utf-8') as f_in:
        with open(csv_file, 'w', newline='', encoding='utf-8') as f_out:
            writer = csv.DictWriter(f_out, fieldnames=['instruction', 'input', 'output'])
            writer.writeheader()
            
            for line_num, line in enumerate(f_in, 1):
                try:
                    data = json.loads(line.strip())
                    convos = data.get('conversations', [])
                    
                    if not convos:
                        continue
                    
                    system_msg = ''
                    human_msg = ''
                    gpt_msg = ''
                    
                    for msg in convos:
                        role = msg.get('from', '')
                        value = msg.get('value', '')
                        
                        if role == 'system':
                            system_msg = value
                        elif role == 'human':
                            human_msg = value
                        elif role == 'gpt':
                            gpt_msg = value
                    
                    if human_msg and gpt_msg:
                        instruction = system_msg or 'You are a helpful AI assistant.'
                        writer.writerow({
                            'instruction': instruction,
                            'input': human_msg,
                            'output': gpt_msg
                        })
                        
                except Exception as e:
                    print(f"⚠ Line {line_num}: {e}")

def main():
    data_dir = Path('/Users/laszloschaffer/projects/mobile_ai_agent/scripts_training/mcp_data')
    
    files = [
        ('train_studio.jsonl', 'train_hf.csv'),
        ('train_clean_studio.jsonl', 'train_clean_hf.csv'),
        ('valid_studio.jsonl', 'valid_hf.csv'),
    ]
    
    for jsonl_name, csv_name in files:
        jsonl_path = data_dir / jsonl_name
        csv_path = data_dir / csv_name
        
        if not jsonl_path.exists():
            print(f"⚠ Skipping {jsonl_name}")
            continue
        
        print(f"📝 Converting {jsonl_name} → {csv_name}")
        jsonl_to_hf_csv(jsonl_path, csv_path)
        
        with open(csv_path) as f:
            rows = sum(1 for _ in f) - 1
        size_kb = csv_path.stat().st_size / 1024
        print(f"   ✅ {csv_name}: {rows} rows ({size_kb:.1f} KB)")
        
        # Show sample
        print(f"   Sample columns:")
        with open(csv_path) as f:
            reader = csv.DictReader(f)
            first = next(reader)
            print(f"     instruction: {first['instruction'][:60]}...")
            print(f"     input: {first['input'][:60]}...")
            print(f"     output: {first['output'][:60]}...")

if __name__ == '__main__':
    main()
