#!/usr/bin/env python3
"""
Convert JSONL training data to proper CSV for Unsloth Studio (Mac).
Handles quote escaping correctly for nested JSON in output column.
"""

import json
import csv
import sys
from pathlib import Path

def jsonl_to_csv_clean(jsonl_file, csv_file):
    """Convert ChatML JSONL to CSV with proper quote escaping."""
    with open(jsonl_file, 'r', encoding='utf-8') as f_in:
        with open(csv_file, 'w', newline='', encoding='utf-8') as f_out:
            writer = csv.writer(f_out, quoting=csv.QUOTE_ALL, escapechar='\\')
            writer.writerow(['text', 'label'])
            
            for line_num, line in enumerate(f_in, 1):
                try:
                    data = json.loads(line.strip())
                    convos = data.get('conversations', [])
                    
                    if not convos:
                        continue
                    
                    # Extract human and gpt messages
                    human_msg = ''
                    gpt_msg = ''
                    
                    for msg in convos:
                        role = msg.get('from', '')
                        value = msg.get('value', '')
                        
                        if role == 'human':
                            human_msg = value
                        elif role == 'gpt':
                            gpt_msg = value
                    
                    if human_msg and gpt_msg:
                        # Create training pair: text = query, label = response
                        writer.writerow([human_msg, gpt_msg])
                        
                except Exception as e:
                    print(f"⚠ Line {line_num}: {e}", file=sys.stderr)

def main():
    data_dir = Path('/Users/laszloschaffer/projects/mobile_ai_agent/scripts_training/mcp_data')
    
    files = [
        ('train_studio.jsonl', 'train_unsloth.csv'),
        ('train_clean_studio.jsonl', 'train_clean_unsloth.csv'),
        ('valid_studio.jsonl', 'valid_unsloth.csv'),
    ]
    
    for jsonl_name, csv_name in files:
        jsonl_path = data_dir / jsonl_name
        csv_path = data_dir / csv_name
        
        if not jsonl_path.exists():
            print(f"⚠ Skipping {jsonl_name} (not found)")
            continue
        
        print(f"📝 Converting {jsonl_name} → {csv_name}")
        jsonl_to_csv_clean(jsonl_path, csv_path)
        
        # Count rows
        with open(csv_path) as f:
            rows = sum(1 for _ in f) - 1  # -1 for header
        size_kb = csv_path.stat().st_size / 1024
        print(f"   ✅ Created {csv_name} with {rows} rows ({size_kb:.1f} KB)")

if __name__ == '__main__':
    main()
