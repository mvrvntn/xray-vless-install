#!/usr/bin/env python3
import ast
import os
import re
import sys

def main():
    script_path = os.environ.get("SCRIPT_PATH", "install_xray.sh")
    if not os.path.exists(script_path):
        # Fallback if run from tests/ dir
        alt_path = os.path.join(os.path.dirname(__file__), "..", "install_xray.sh")
        if os.path.exists(alt_path):
            script_path = alt_path
        else:
            print(f"Error: {script_path} not found", file=sys.stderr)
            sys.exit(1)

    with open(script_path, "r", encoding="utf-8") as f:
        content = f.read()

    # 1. Parse SUB_SERVER_SCRIPT heredoc
    sub_match = re.search(r'cat\s*>\s*"\$SUB_SERVER_SCRIPT"\s*<<\s*\'?EOF\'?\n(.*?)\nEOF', content, re.DOTALL)
    if not sub_match:
        print("Error: SUB_SERVER_SCRIPT block not found", file=sys.stderr)
        sys.exit(1)

    try:
        ast.parse(sub_match.group(1))
        print("[OK] SUB_SERVER_SCRIPT python parsed successfully")
    except SyntaxError as e:
        print(f"SyntaxError in SUB_SERVER_SCRIPT: {e}", file=sys.stderr)
        sys.exit(1)

    # 2. Parse all multiline python3 -c '...' blocks
    py_c_matches = re.findall(r'python3\s+-c\s+\'(.*?)\'', content, re.DOTALL)
    parsed_c_count = 0
    for i, block in enumerate(py_c_matches):
        if '\n' in block:
            try:
                ast.parse(block)
                parsed_c_count += 1
            except SyntaxError as e:
                print(f"SyntaxError in python3 -c block {i+1}: {e}", file=sys.stderr)
                sys.exit(1)

    print(f"[OK] {parsed_c_count} multiline python3 -c block(s) parsed successfully")
    print("All embedded Python syntax validated successfully!")

if __name__ == "__main__":
    main()
