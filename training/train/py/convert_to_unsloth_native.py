#!/usr/bin/env python3
"""
Convert training data to Unsloth native format: JSONL with 'messages' array.
This is the format Unsloth Studio uses internally and doesn't require recipe mapping.
"""

import json
from pathlib import Path

def convert_to_unsloth_format(jsonl_file, output_file):
    """Convert to Unsloth's native messages format."""
    with open(jsonl_file, 'r', encoding='utf-8') as f_in:
        with open(output_file, 'w', encoding='utf-8') as f_out:
            for line_num, line in enumerate(f_in, 1):
                try:
                    data = json.loads(line.strip())
                    convos = data.get('conversations', [])
                    
                    if not convos:
                        continue
                    
                    # Convert to Unsloth format: role (system/user/assistant) with content
                    messages = []
                    for msg in convos:
                        role_map = {'system': 'system', 'human': 'user', 'gpt': 'assistant'}
                        role = role_map.get(msg.get('from', 'user'))
                        content = msg.get('value', '')
                        
                        if role and content:
                            messages.append({'role': role, 'content': content})
                    
                    if messages:
                        output_record = {'messages': messages}
                        f_out.write(json.dumps(output_record) + '\n')
                        
                except Exception as e:
                    print(f"⚠ Line {line_num}: {e}")

def main():
    data_dir = Path('/Users/laszloschaffer/projects/mobile_ai_agent/scripts_training/mcp_data')
    
    files = [
        ('train_studio.jsonl', 'train_unsloth_native.jsonl'),
        ('train_clean_studio.jsonl', 'train_clean_unsloth_native.jsonl'),
        ('valid_studio.jsonl', 'valid_unsloth_native.jsonl'),
    ]
    
    for jsonl_name, output_name in files:
        jsonl_path = data_dir / jsonl_name
        output_path = data_dir / output_name
        
        if not jsonl_path.exists():
            print(f"⚠ Skipping {jsonl_name}")
            continue
        
        print(f"📝 Converting {jsonl_name} → {output_name}")
        convert_to_unsloth_format(jsonl_path, output_path)
        
        with open(output_path) as f:
            rows = sum(1 for _ in f)
        size_kb = output_path.stat().st_size / 1024
        print(f"   ✅ {output_name}: {rows} rows ({size_kb:.1f} KB)")
        
        # Show first record
        with open(output_path) as f:
            first = json.loads(f.readline())
            print(f"   Sample record: {json.dumps(first, indent=2)[:200]}...")

if __name__ == '__main__':
    main()
