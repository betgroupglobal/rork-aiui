#!/usr/bin/env python3
"""
Featherless AI Workspace Error Checker & Self-Healing Trigger
Scans repository files for syntax/compilation errors and unhandled exceptions.
Optionally triggers Featherless AI self-healing fixer immediately.
"""

import os
import sys
import glob
import json
import py_compile
import argparse
from typing import List, Dict, Any

try:
    from error_fixer import FeatherlessSelfHealer
    HAS_FIXER = True
except ImportError:
    HAS_FIXER = False


def check_python_file(file_path: str) -> Dict[str, Any]:
    """Check python file syntax using py_compile"""
    try:
        py_compile.compile(file_path, doraise=True)
        return {"file": file_path, "ok": True}
    except py_compile.PyCompileError as e:
        msg = str(e.exc_value) if hasattr(e, 'exc_value') else str(e)
        line = getattr(e, 'lineno', None)
        return {
            "file": file_path,
            "ok": False,
            "type": "SyntaxError",
            "message": msg,
            "line": line
        }
    except Exception as e:
        return {
            "file": file_path,
            "ok": False,
            "type": type(e).__name__,
            "message": str(e)
        }


def check_json_file(file_path: str) -> Dict[str, Any]:
    """Validate JSON syntax"""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            json.load(f)
        return {"file": file_path, "ok": True}
    except Exception as e:
        return {
            "file": file_path,
            "ok": False,
            "type": "JSONDecodeError",
            "message": str(e)
        }


def scan_workspace(root_dir: str = ".") -> List[Dict[str, Any]]:
    """Scan all code files in directory for syntax errors"""
    errors = []
    root = os.path.abspath(root_dir)
    exclude_dirs = {"node_modules", ".git", ".venv", "venv", "__pycache__", "dist", "build"}

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in exclude_dirs]
        for f in filenames:
            ext = os.path.splitext(f)[1].lower()
            full_path = os.path.join(dirpath, f)
            rel_path = os.path.relpath(full_path, root)

            if ext == ".py":
                res = check_python_file(full_path)
                if not res["ok"]:
                    res["rel_path"] = rel_path
                    errors.append(res)
            elif ext == ".json":
                res = check_json_file(full_path)
                if not res["ok"]:
                    res["rel_path"] = rel_path
                    errors.append(res)

    return errors


def main():
    parser = argparse.ArgumentParser(description="Featherless Error Checker with Self-Healing")
    parser.add_argument("--dir", default=".", help="Directory to scan (default: .)")
    parser.add_argument("--heal", action="store_true", help="Automatically invoke Featherless AI to fix errors")
    parser.add_argument("--run", help="Run a specific command and self-heal on failure")
    args = parser.parse_args()

    print(f"🔍 [ERROR CHECKER] Scanning workspace: {os.path.abspath(args.dir)}")

    if args.run:
        if args.heal and HAS_FIXER:
            healer = FeatherlessSelfHealer(work_dir=args.dir)
            ok = healer.heal_runtime_error(args.run)
            sys.exit(0 if ok else 1)
        else:
            import subprocess
            res = subprocess.run(args.run, shell=True, cwd=args.dir)
            sys.exit(res.returncode)

    errors = scan_workspace(args.dir)

    if not errors:
        print("✅ Zero errors detected! All Python and JSON files compile cleanly.")
        sys.exit(0)

    print(f"\n⚠️ Detected {len(errors)} error(s) in workspace:")
    for err in errors:
        print(f"  • {err.get('rel_path', err['file'])}: {err.get('type')} - {err.get('message')}")

    if args.heal:
        if not HAS_FIXER:
            print("❌ error_fixer module not found. Cannot run self-healing.")
            sys.exit(1)

        print("\n🩹 [SELF-HEALING MODE ACTIVATED] Invoking Featherless AI to resolve errors...")
        healer = FeatherlessSelfHealer(work_dir=args.dir)
        repaired_count = 0

        for err in errors:
            success = healer.heal_file_syntax(
                err["file"],
                err.get("message", "Syntax error"),
                line_no=err.get("line")
            )
            if success:
                repaired_count += 1

        print(f"\n🎉 Self-healing pass completed: {repaired_count}/{len(errors)} error(s) fixed.")
        # Re-check
        remaining = scan_workspace(args.dir)
        if not remaining:
            print("✨ 100% of errors successfully healed!")
            sys.exit(0)
        else:
            print(f"⚠️ {len(remaining)} error(s) remain.")
            sys.exit(1)
    else:
        print("\n💡 Tip: Run with --heal to automatically fix these errors using Featherless AI.")
        sys.exit(1)


if __name__ == "__main__":
    main()
