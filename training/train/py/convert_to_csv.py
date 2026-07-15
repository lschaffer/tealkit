#!/usr/bin/env python3
"""
Convert JSONL training data to CSV format for Unsloth Studio.
JSONL format: {"conversations": [{"from": "role", "value": "text"}, ...]}
CSV output: instruction | input | output
"""

import json
import csv
import sys
from pathlib import Path

def jsonl_to_csv(jsonl_file, csv_file):
    """Convert ChatML JSONL to CSV with instruction|input|output format."""
    with open(jsonl_file, 'r') as f_in, open(csv_file, 'w', newline='') as f_out:
        writer = csv.writer(f_out)
        writer.writerow(['instruction', 'input', 'output'])
        
        for line_num, line in enumerate(f_in, 1):
            try:
                data = json.loads(line.strip())
                convos = data.get('conversations', [])
                
                if not convos:
                    print(f"⚠ Line {line_num}: No conversations field")
                    continue
                
                # Extract system, human (input), and gpt (output)
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
                    instruction = system_msg if system_msg else 'You are a helpful AI assistant.'
                    writer.writerow([instruction, human_msg, gpt_msg])
            except json.JSONDecodeError as e:
                print(f"⚠ Line {line_num}: Invalid JSON — {e}")
            except Exception as e:
                print(f"⚠ Line {line_num}: {e}")

def main():
    data_dir = Path('/Users/laszloschaffer/projects/mobile_ai_agent/scripts_training/mcp_data')
    
    files = [
        ('train_studio.jsonl', 'train_studio.csv'),
        ('train_clean_studio.jsonl', 'train_clean_studio.csv'),
        ('valid_studio.jsonl', 'valid_studio.csv'),
    ]
    
    for jsonl_name, csv_name in files:
        jsonl_path = data_dir / jsonl_name
        csv_path = data_dir / csv_name
        
        if not jsonl_path.exists():
            print(f"⚠ Skipping {jsonl_name} (not found)")
            continue
        
        print(f"\n📝 Converting {jsonl_name} → {csv_name}")
        jsonl_to_csv(jsonl_path, csv_path)
        
        # Count rows
        with open(csv_path) as f:
            rows = sum(1 for _ in f) - 1  # -1 for header
        print(f"   ✅ Created {csv_path.name} with {rows} rows")

if __name__ == '__main__':
    main()
