#!/usr/bin/env python3
"""
Featherless AI Self-Healing Error Fixer
Autonomously diagnoses and repairs syntax errors and runtime failures using the Featherless.ai API.
"""

import os
import sys
import json
import re
import py_compile
import subprocess
import argparse
from typing import Optional, Dict, Any, List, Tuple

try:
    import requests
except ImportError:
    print("Error: requests library not installed. Run: pip install requests")
    sys.exit(1)

DEFAULT_API_KEY = os.environ.get(
    "FEATHERLESS_API_KEY",
    "rc_a939625b5ebea3e527e07ee81d1d3ac10a77be72203eed6e53c3a81f4174a86a"
)
DEFAULT_BASE_URL = os.environ.get("FEATHERLESS_BASE_URL", "https://api.featherless.ai/v1")
DEFAULT_MODEL = os.environ.get("FEATHERLESS_MODEL", "Qwen/Qwen2.5-7B-Instruct")


class FeatherlessSelfHealer:
    """Self-healing engine powered by Featherless AI"""

    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        model: Optional[str] = None,
        work_dir: str = "."
    ):
        self.api_key = api_key or DEFAULT_API_KEY
        self.base_url = (base_url or DEFAULT_BASE_URL).rstrip('/')
        self.model = model or DEFAULT_MODEL
        self.work_dir = os.path.abspath(work_dir)

    def _call_api(self, prompt: str, system_prompt: Optional[str] = None, max_tokens: int = 4096) -> str:
        """Call Featherless chat completions API"""
        url = f"{self.base_url}/chat/completions"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})

        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": 0.2
        }

        try:
            resp = requests.post(url, headers=headers, json=payload, timeout=60)
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"]
        except Exception as e:
            print(f"❌ Featherless API call failed: {e}")
            return ""

    def heal_file_syntax(self, file_path: str, error_msg: str, line_no: Optional[int] = None) -> bool:
        """Fix syntax, indentation, or compilation error in a file"""
        full_path = os.path.abspath(os.path.join(self.work_dir, file_path)) if not os.path.isabs(file_path) else file_path
        if not os.path.exists(full_path):
            print(f"❌ File not found: {full_path}")
            return False

        print(f"\n🩺 [SELF-HEAL] Repairing syntax in: {os.path.basename(full_path)}")
        print(f"   Error: {error_msg} (line {line_no or 'unknown'})")

        try:
            with open(full_path, "r", encoding="utf-8", errors="replace") as f:
                code = f.read()
        except Exception as e:
            print(f"❌ Could not read {full_path}: {e}")
            return False

        system_prompt = (
            "You are an expert self-healing code fixer. Your job is to resolve syntax errors, "
            "indentation bugs, typos, and unhandled issues with precision. "
            "Always return ONLY the complete, corrected code wrapped in a single ```python code block. "
            "Do not include conversational chatter."
        )

        user_prompt = f"""File: {os.path.basename(full_path)}
Error Message: {error_msg}
Line Number: {line_no}

Source Code:
```python
{code}
```

Task: Fix the syntax or structural error. Return ONLY the complete fixed code within ```python ... ```."""

        response = self._call_api(user_prompt, system_prompt=system_prompt)
        if not response:
            return False

        match = re.search(r"```(?:python)?\s*\n(.*?)```", response, re.DOTALL)
        fixed_code = match.group(1) if match else response.strip()

        if not fixed_code or fixed_code == code:
            print("⚠️ Featherless suggested no modifications.")
            return False

        backup_path = full_path + ".bak"
        try:
            with open(backup_path, "w", encoding="utf-8") as f:
                f.write(code)

            with open(full_path, "w", encoding="utf-8") as f:
                f.write(fixed_code)

            if full_path.endswith(".py"):
                py_compile.compile(full_path, doraise=True)

            print(f"✅ [SELF-HEAL SUCCESS] {os.path.basename(full_path)} repaired and verified cleanly!")
            if os.path.exists(backup_path):
                os.remove(backup_path)
            return True
        except py_compile.PyCompileError as pe:
            print(f"⚠️ Fixed code still had syntax error: {pe}. Restoring backup.")
            if os.path.exists(backup_path):
                with open(backup_path, "r", encoding="utf-8") as f:
                    with open(full_path, "w", encoding="utf-8") as orig:
                        orig.write(f.read())
                os.remove(backup_path)
            return False
        except Exception as e:
            print(f"❌ Verification failed: {e}")
            if os.path.exists(backup_path):
                with open(backup_path, "r", encoding="utf-8") as f:
                    with open(full_path, "w", encoding="utf-8") as orig:
                        orig.write(f.read())
                os.remove(backup_path)
            return False

    def heal_runtime_error(self, command: str, max_rounds: int = 5) -> bool:
        """Run a command, catch runtime errors/tracebacks, and autonomously fix them until exit code is 0"""
        print(f"\n🚀 [SELF-HEAL RUNNER] Executing: {command}")
        
        for round_idx in range(1, max_rounds + 1):
            res = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                cwd=self.work_dir
            )

            if res.returncode == 0:
                print(f"✨ [HEAL VERIFIED] Command succeeded with exit code 0 on round {round_idx}!")
                if res.stdout.strip():
                    print(f"STDOUT:\n{res.stdout.strip()}")
                return True

            stderr = res.stderr.strip()
            stdout = res.stdout.strip()
            print(f"\n🩹 [ROUND {round_idx}/{max_rounds}] Command failed with exit code {res.returncode}")
            if stderr:
                print(f"STDERR:\n{stderr[:1000]}")

            file_match = re.findall(r'File "([^"]+\.py)", line (\d+)', stderr)
            target_file = None
            target_line = None
            if file_match:
                for f_path, l_num in reversed(file_match):
                    if not f_path.startswith("<") and "site-packages" not in f_path and "lib/python" not in f_path:
                        target_file = f_path
                        target_line = int(l_num)
                        break

            file_context = ""
            if target_file and os.path.exists(os.path.join(self.work_dir, target_file)):
                actual_path = os.path.join(self.work_dir, target_file)
                with open(actual_path, "r", encoding="utf-8", errors="replace") as f:
                    file_lines = f.readlines()
                total = len(file_lines)
                start = max(1, target_line - 20)
                end = min(total, target_line + 20)
                snippet = "".join(file_lines[start - 1:end])
                file_context = f"\nFailing File: {target_file} (Lines {start}-{end}):\n```python\n{snippet}\n```"

            system_prompt = (
                "You are an expert self-healing engineer. You analyze terminal errors and Python tracebacks, "
                "then output the exact code fix. "
                "Output your response in format:\n"
                "FILE: <filename>\n"
                "```python\n<full fixed file content>\n```"
            )

            user_prompt = f"""Command: {command}
Exit Code: {res.returncode}
Stderr / Traceback:
{stderr}

Stdout:
{stdout}
{file_context}

Task: Diagnose the root cause and provide the complete fixed code for the broken file to make the command pass."""

            print("🧠 Requesting fix from Featherless AI...")
            resp = self._call_api(user_prompt, system_prompt=system_prompt)
            if not resp:
                print("❌ No response from Featherless AI.")
                continue

            target_name = None
            f_match = re.search(r"FILE:\s*([^\s\n]+)", resp)
            if f_match:
                target_name = f_match.group(1).strip()
            elif target_file:
                target_name = target_file

            c_match = re.search(r"```(?:python)?\s*\n(.*?)```", resp, re.DOTALL)
            if c_match and target_name:
                fixed_code = c_match.group(1)
                dest = os.path.abspath(os.path.join(self.work_dir, target_name)) if not os.path.isabs(target_name) else target_name
                print(f"📝 Applying Featherless AI patch to: {os.path.basename(dest)}")
                with open(dest, "w", encoding="utf-8") as f:
                    f.write(fixed_code)
            else:
                print("⚠️ Could not extract clean code block patch from response.")

        print(f"\n❌ Self-healing did not resolve all errors after {max_rounds} rounds.")
        return False


def main():
    parser = argparse.ArgumentParser(description="Featherless AI Autonomous Self-Healing Error Fixer")
    parser.add_argument("--cmd", help="Run command and self-heal any errors until exit code 0")
    parser.add_argument("--file", help="Specific file path to heal")
    parser.add_argument("--error", help="Error description or traceback")
    parser.add_argument("--line", type=int, help="Error line number")
    parser.add_argument("--max-rounds", type=int, default=5, help="Maximum healing rounds (default: 5)")
    parser.add_argument("--dir", default=".", help="Working directory (default: current)")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Featherless model ID")

    args = parser.parse_args()
    healer = FeatherlessSelfHealer(work_dir=args.dir, model=args.model)

    if args.cmd:
        success = healer.heal_runtime_error(args.cmd, max_rounds=args.max_rounds)
        sys.exit(0 if success else 1)
    elif args.file and args.error:
        success = healer.heal_file_syntax(args.file, args.error, line_no=args.line)
        sys.exit(0 if success else 1)
    else:
        print("Featherless AI Self-Healing Error Fixer initialized.")
        print("Usage: python3 error_fixer.py --cmd '<command>' or --file <file> --error '<err>'")
        sys.exit(0)


if __name__ == "__main__":
    main()
