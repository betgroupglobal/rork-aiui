#!/usr/bin/env python3
"""
Featherless Autonomous Terminal Agent
An interactive, autonomous terminal-based AI assistant powered by Featherless.ai.
Capable of running commands, reading/writing files, editing scripts, and debugging autonomously.
"""

import os
import sys
import json
import argparse
import subprocess
import re
import glob
import shutil
from typing import List, Dict, Optional, Tuple, Any
from datetime import datetime

try:
    import requests
except ImportError:
    print("Error: requests library not installed. Run: pip install requests")
    sys.exit(1)

try:
    from rich.console import Console
    from rich.markdown import Markdown
    from rich.panel import Panel
    from rich.text import Text
    from rich.syntax import Syntax
    from rich.table import Table
    from rich.rule import Rule
    from rich.live import Live
    from rich.spinner import Spinner
    from rich.align import Align
    from rich.columns import Columns
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False
    print("Note: rich library not installed. Install for better formatting: pip install rich")


DEFAULT_API_KEY = "rc_a939625b5ebea3e527e07ee81d1d3ac10a77be72203eed6e53c3a81f4174a86a"

DEFAULT_SYSTEM_PROMPT = """You are Featherless Autonomous Agent, an advanced software engineering and terminal assistant.
You operate directly in the user's workspace with real tool capabilities to inspect files, execute terminal commands, write new files, and edit existing scripts autonomously.

AVAILABLE TOOLS:
To use a tool, output an XML tool block. You can invoke tools one by one or in sequence:

1. Run shell command:
<tool name="run_command">
<command>python3 script.py</command>
</tool>

2. Read file:
<tool name="read_file">
<path>filename.py</path>
<start_line>1</start_line>
<end_line>100</end_line>
</tool>

3. Write or create a file:
<tool name="write_file">
<path>filename.py</path>
<content>
def hello():
    print("Hello World")
</content>
</tool>

4. Edit an existing file:
<tool name="edit_file">
<path>filename.py</path>
<old_text>exact text to replace</old_text>
<new_text>replacement text</new_text>
</tool>

5. List directory contents:
<tool name="list_dir">
<path>.</path>
</tool>

6. Search text patterns in files:
<tool name="search_files">
<query>search text</query>
<path>.</path>
</tool>

OPERATIONAL WORKFLOW:
- When asked to complete a task, edit code, or run a program:
  1. Inspect the workspace or read relevant files first.
  2. Implement changes or write scripts using write_file or edit_file.
  3. Execute commands to verify, test, or run scripts.
  4. If you encounter errors, inspect the output, diagnose, and fix them autonomously.
  5. Once the task is fully achieved and verified, provide a clean summary without calling tools.
"""


class ChatMessage:
    def __init__(self, role: str, content: str, timestamp: datetime = None):
        self.role = role
        self.content = content
        self.timestamp = timestamp or datetime.now()
    
    def to_dict(self) -> dict:
        return {
            "role": self.role,
            "content": self.content
        }


class AgentTools:
    """Tool execution engine for the autonomous agent"""
    def __init__(self, work_dir: str = "."):
        self.work_dir = os.path.abspath(work_dir)
    
    def _resolve_path(self, path: str) -> str:
        path = os.path.expanduser(path.strip())
        if not os.path.isabs(path):
            path = os.path.join(self.work_dir, path)
        return os.path.normpath(path)
    
    def run_command(self, command: str, timeout: int = 120) -> str:
        """Run a shell command and capture stdout/stderr/exitcode"""
        command = command.strip()
        if not command:
            return "Error: Empty command"
        
        try:
            res = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=self.work_dir
            )
            stdout = res.stdout.strip()
            stderr = res.stderr.strip()
            
            output_lines = [f"Exit Code: {res.returncode}"]
            if stdout:
                if len(stdout) > 6000:
                    truncated = stdout[:6000] + f"\n... [Output truncated. {len(stdout) - 6000} characters omitted]"
                    output_lines.append(f"STDOUT:\n{truncated}")
                else:
                    output_lines.append(f"STDOUT:\n{stdout}")
            if stderr:
                if len(stderr) > 4000:
                    truncated = stderr[:4000] + f"\n... [Stderr truncated. {len(stderr) - 4000} characters omitted]"
                    output_lines.append(f"STDERR:\n{truncated}")
                else:
                    output_lines.append(f"STDERR:\n{stderr}")
            if not stdout and not stderr:
                output_lines.append("(No output produced)")
            
            return "\n".join(output_lines)
        except subprocess.TimeoutExpired:
            return f"Error: Command timed out after {timeout} seconds."
        except Exception as e:
            return f"Error executing command: {str(e)}"
    
    def read_file(self, path: str, start_line: Optional[int] = None, end_line: Optional[int] = None) -> str:
        """Read file contents with line numbers and optional line slicing"""
        full_path = self._resolve_path(path)
        if not os.path.exists(full_path):
            return f"Error: File '{path}' does not exist."
        if os.path.isdir(full_path):
            return f"Error: '{path}' is a directory, not a file. Use list_dir instead."
        
        try:
            try:
                with open(full_path, "r", encoding="utf-8") as f:
                    lines = f.readlines()
            except UnicodeDecodeError:
                with open(full_path, "r", encoding="latin-1") as f:
                    lines = f.readlines()
            
            total_lines = len(lines)
            start = max(1, start_line or 1)
            end = min(total_lines, end_line or total_lines)
            
            if start > total_lines:
                return f"File '{path}' has {total_lines} lines. Requested start_line {start} is out of range."
            
            result = [f"File: {path} (Showing lines {start}-{end} of {total_lines})"]
            for i in range(start - 1, end):
                result.append(f"{i + 1:4d} | {lines[i].rstrip()}")
            
            return "\n".join(result)
        except Exception as e:
            return f"Error reading file '{path}': {str(e)}"
    
    def write_file(self, path: str, content: str) -> str:
        """Create or overwrite a file"""
        full_path = self._resolve_path(path)
        try:
            parent = os.path.dirname(full_path)
            if parent and not os.path.exists(parent):
                os.makedirs(parent, exist_ok=True)
            
            with open(full_path, "w", encoding="utf-8") as f:
                f.write(content)
            
            lines = content.splitlines()
            return f"Success: Written {len(content)} bytes ({len(lines)} lines) to '{path}'."
        except Exception as e:
            return f"Error writing file '{path}': {str(e)}"
    
    def edit_file(self, path: str, old_text: str, new_text: str) -> str:
        """Replace exact target text in an existing file"""
        full_path = self._resolve_path(path)
        if not os.path.exists(full_path):
            return f"Error: File '{path}' does not exist."
        
        try:
            with open(full_path, "r", encoding="utf-8") as f:
                content = f.read()
            
            if old_text not in content:
                # Provide a helpful excerpt
                sample = content[:400] if len(content) > 400 else content
                return (f"Error: Target text not found in '{path}'. Make sure whitespace and formatting match exactly.\n"
                        f"Current file preview:\n{sample}")
            
            count = content.count(old_text)
            if count > 1:
                return f"Warning: Target text occurs {count} times in '{path}'. Please include more surrounding context lines to ensure unique replacement."
            
            new_content = content.replace(old_text, new_text, 1)
            with open(full_path, "w", encoding="utf-8") as f:
                f.write(new_content)
            
            return f"Success: Successfully edited '{path}' (replaced 1 instance)."
        except Exception as e:
            return f"Error editing file '{path}': {str(e)}"
    
    def list_dir(self, path: str = ".") -> str:
        """List directory items with sizes and types"""
        full_path = self._resolve_path(path)
        if not os.path.exists(full_path):
            return f"Error: Directory '{path}' does not exist."
        if not os.path.isdir(full_path):
            return f"Error: '{path}' is not a directory."
        
        try:
            entries = sorted(os.listdir(full_path))
            dirs = []
            files = []
            for e in entries:
                if e.startswith(".git"):
                    continue
                p = os.path.join(full_path, e)
                if os.path.isdir(p):
                    dirs.append(f"📁 {e}/")
                else:
                    size = os.path.getsize(p)
                    if size < 1024:
                        s_str = f"{size} B"
                    elif size < 1024 * 1024:
                        s_str = f"{size / 1024:.1f} KB"
                    else:
                        s_str = f"{size / (1024 * 1024):.1f} MB"
                    files.append(f"📄 {e:<30} ({s_str})")
            
            header = f"Directory: {path} ({len(dirs)} folders, {len(files)} files)"
            items = dirs + files
            return header + "\n" + ("\n".join(items) if items else "(Empty directory)")
        except Exception as e:
            return f"Error listing directory '{path}': {str(e)}"
    
    def search_files(self, query: str, path: str = ".") -> str:
        """Search text patterns across workspace files"""
        full_path = self._resolve_path(path)
        query = query.strip()
        if not query:
            return "Error: Empty search query."
        
        matches = []
        try:
            for root, dirs, filenames in os.walk(full_path):
                # Skip hidden/large folders
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "vendor", "__pycache__", "build", "dist")]
                for fn in filenames:
                    if fn.startswith("."):
                        continue
                    file_path = os.path.join(root, fn)
                    rel_path = os.path.relpath(file_path, self.work_dir)
                    try:
                        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                            for idx, line in enumerate(f, 1):
                                if query.lower() in line.lower():
                                    matches.append(f"{rel_path}:{idx}: {line.strip()[:140]}")
                                    if len(matches) >= 50:
                                        break
                    except Exception:
                        pass
                    if len(matches) >= 50:
                        break
                if len(matches) >= 50:
                    break
            
            if not matches:
                return f"No matches found for '{query}' in '{path}'."
            return f"Found {len(matches)} match(es) for '{query}':\n" + "\n".join(matches)
        except Exception as e:
            return f"Error searching files: {str(e)}"


class ToolCallParser:
    """Parses tool invocations from LLM outputs"""
    
    @staticmethod
    def parse(text: str) -> List[Dict[str, Any]]:
        tools = []
        
        # Pattern 1: XML <tool name="...">...</tool>
        xml_pattern = re.compile(
            r'<tool\s+name=["\']([^"\']+)["\'](?:\s+path=["\']([^"\']*)["\'])?(?:\s+start_line=["\'](\d*)["\'])?(?:\s+end_line=["\'](\d*)["\'])?\s*>(.*?)</tool>',
            re.DOTALL | re.IGNORECASE
        )
        for m in xml_pattern.finditer(text):
            name = m.group(1).strip().lower()
            body = m.group(5).strip()
            args = {}
            if m.group(2): args['path'] = m.group(2).strip()
            if m.group(3): args['start_line'] = int(m.group(3))
            if m.group(4): args['end_line'] = int(m.group(4))
            
            subtags = ['command', 'path', 'content', 'old_text', 'new_text', 'query', 'start_line', 'end_line']
            found_subtag = False
            for tag in subtags:
                sub_match = re.search(rf'<{tag}>(.*?)</{tag}>', body, re.DOTALL | re.IGNORECASE)
                if sub_match:
                    found_subtag = True
                    val = sub_match.group(1)
                    if tag in ('start_line', 'end_line'):
                        try: val = int(val.strip())
                        except: pass
                    elif tag == 'content':
                        # Preserve code indentation but strip boundary newlines
                        val = val.strip('\r\n')
                    else:
                        val = val.strip()
                    args[tag] = val
            
            if not found_subtag and body:
                if name in ('run_command', 'bash', 'shell', 'exec', 'sh'):
                    name = 'run_command'
                    args['command'] = body
                elif name in ('read_file', 'cat', 'view'):
                    name = 'read_file'
                    args['path'] = body
                elif name in ('list_dir', 'ls'):
                    name = 'list_dir'
                    args['path'] = body
                elif name in ('search_files', 'grep'):
                    name = 'search_files'
                    args['query'] = body
            
            # Normalize name aliases
            if name in ('bash', 'shell', 'exec', 'sh'): name = 'run_command'
            elif name in ('cat', 'view'): name = 'read_file'
            elif name in ('ls', 'dir'): name = 'list_dir'
            elif name == 'grep': name = 'search_files'
            
            tools.append({'tool': name, 'args': args})
        
        # Pattern 2: JSON blocks
        if not tools:
            json_pattern = re.compile(r'```(?:json)?\s*(\{\s*"(?:tool|action)"\s*:.*?\})\s*```', re.DOTALL)
            for m in json_pattern.finditer(text):
                try:
                    data = json.loads(m.group(1))
                    name = (data.get('tool') or data.get('action', '')).strip().lower()
                    args = data.get('args', {})
                    if not args:
                        args = {k: v for k, v in data.items() if k not in ('tool', 'action')}
                    if name in ('bash', 'shell', 'exec', 'sh'): name = 'run_command'
                    tools.append({'tool': name, 'args': args})
                except Exception:
                    pass
        
        # Pattern 3: Direct ```bash ... ``` code blocks
        if not tools:
            bash_pattern = re.compile(r'```(?:bash|sh)\s*\n(.*?)```', re.DOTALL)
            for m in bash_pattern.finditer(text):
                cmd = m.group(1).strip()
                if cmd and not cmd.startswith("#"):
                    tools.append({'tool': 'run_command', 'args': {'command': cmd}})
        
        return tools
    
    @staticmethod
    def strip_tool_blocks(text: str) -> str:
        """Strip tool blocks from text to leave thoughts and explanations"""
        cleaned = re.sub(r'<tool\s+name=["\'][^"\']+["\'].*?</tool>', '', text, flags=re.DOTALL | re.IGNORECASE)
        cleaned = re.sub(r'```(?:json)?\s*\{\s*"(?:tool|action)"\s*:.*?\}\s*```', '', cleaned, flags=re.DOTALL)
        return cleaned.strip()


class FeatherlessChatAgent:
    def __init__(self, api_key: Optional[str] = None, base_url: str = "https://api.featherless.ai/v1", 
                 model: str = "Qwen/Qwen2.5-7B-Instruct", system_prompt: Optional[str] = None,
                 autonomous: bool = True, require_confirm: bool = False, max_steps: int = 25,
                 work_dir: str = "."):
        # Resolve API Key
        if not api_key:
            api_key = os.environ.get("FEATHERLESS_API_KEY")
        if not api_key:
            env_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
            if os.path.exists(env_file):
                try:
                    with open(env_file) as f:
                        for line in f:
                            if line.strip().startswith("FEATHERLESS_API_KEY="):
                                api_key = line.strip().split("=", 1)[1].strip("\"' ")
                                break
                except Exception:
                    pass
        self.api_key = api_key or DEFAULT_API_KEY
        self.base_url = base_url
        self.model = model
        self.system_prompt = system_prompt or DEFAULT_SYSTEM_PROMPT
        self.conversation_history: List[ChatMessage] = []
        self.max_history = 30
        
        # Autonomous execution configuration
        self.autonomous_mode = autonomous
        self.require_confirm = require_confirm
        self.max_steps = max_steps
        self.tools = AgentTools(work_dir=work_dir)
        
        if not self.api_key:
            print("Error: FEATHERLESS_API_KEY not set. Set it as environment variable or use --api-key")
            sys.exit(1)
        
        self.console = Console() if RICH_AVAILABLE else None
    
    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
    
    def _add_to_history(self, role: str, content: str):
        message = ChatMessage(role, content)
        self.conversation_history.append(message)
        if len(self.conversation_history) > self.max_history:
            self.conversation_history = self.conversation_history[-self.max_history:]
    
    def _build_api_messages(self) -> List[dict]:
        messages = []
        if self.system_prompt:
            messages.append({"role": "system", "content": self.system_prompt})
        for msg in self.conversation_history:
            messages.append(msg.to_dict())
        return messages
    
    def _call_api(self) -> Optional[str]:
        """Make a single chat completion API call"""
        messages = self._build_api_messages()
        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": 2500,
            "temperature": 0.4
        }
        
        try:
            if RICH_AVAILABLE:
                with self.console.status("[bold bright_green]🤖 Featherless Agent is thinking...", spinner="dots"):
                    response = requests.post(
                        f"{self.base_url}/chat/completions",
                        headers=self._headers(),
                        json=payload,
                        timeout=90
                    )
            else:
                print("🤖 Featherless Agent is thinking...")
                response = requests.post(
                    f"{self.base_url}/chat/completions",
                    headers=self._headers(),
                    json=payload,
                    timeout=90
                )
            
            if response.status_code != 200:
                if RICH_AVAILABLE:
                    self.console.print(Panel(
                        f"❌ API Error: HTTP {response.status_code}\n{response.text}",
                        border_style="bright_red"
                    ))
                else:
                    print(f"API Error: HTTP {response.status_code}\n{response.text}")
                return None
            
            data = response.json()
            return data["choices"][0]["message"]["content"]
        except requests.exceptions.Timeout:
            if RICH_AVAILABLE:
                self.console.print(Panel("⏰ API request timed out.", border_style="bright_red"))
            else:
                print("API request timed out.")
            return None
        except Exception as e:
            if RICH_AVAILABLE:
                self.console.print(Panel(f"❌ Error: {str(e)}", border_style="bright_red"))
            else:
                print(f"Error: {str(e)}")
            return None
    
    def execute_tool(self, tool_name: str, args: Dict[str, Any]) -> str:
        """Dispatch tool execution to AgentTools with formatted display"""
        tool_name = tool_name.lower().strip()
        
        # Display Tool Call Banner
        if RICH_AVAILABLE:
            banner = Text()
            banner.append("⚡ TOOL ACTION: ", style="bold bright_yellow")
            banner.append(tool_name.upper(), style="bold bright_cyan")
            
            details = []
            if "command" in args:
                details.append(f"command: {args['command']}")
            if "path" in args:
                details.append(f"path: {args['path']}")
            if "query" in args:
                details.append(f"query: {args['query']}")
            
            info_str = " • ".join(details)
            self.console.print(Panel(
                info_str if info_str else json.dumps(args, indent=2),
                title=banner,
                title_align="left",
                border_style="bright_yellow",
                padding=(0, 1)
            ))
        else:
            print(f"\n⚡ TOOL ACTION: {tool_name} | {args}")
        
        # Confirmation check if enabled
        if self.require_confirm:
            prompt_str = f"Execute tool '{tool_name}'? [Y/n/all/cancel]: "
            if RICH_AVAILABLE:
                choice = self.console.input(f"[bold yellow]{prompt_str}[/bold yellow]").strip().lower()
            else:
                choice = input(prompt_str).strip().lower()
            
            if choice == "all":
                self.require_confirm = False
            elif choice in ("n", "no", "skip"):
                return "Execution skipped by user."
            elif choice in ("cancel", "c"):
                return "Execution cancelled by user."
        
        # Execute tool
        result = ""
        if tool_name == "run_command":
            cmd = args.get("command", "")
            result = self.tools.run_command(cmd)
        elif tool_name == "read_file":
            path = args.get("path", "")
            start = args.get("start_line")
            end = args.get("end_line")
            result = self.tools.read_file(path, start_line=start, end_line=end)
        elif tool_name == "write_file":
            path = args.get("path", "")
            content = args.get("content", "")
            result = self.tools.write_file(path, content)
        elif tool_name == "edit_file":
            path = args.get("path", "")
            old_text = args.get("old_text", "")
            new_text = args.get("new_text", "")
            result = self.tools.edit_file(path, old_text, new_text)
        elif tool_name == "list_dir":
            path = args.get("path", ".")
            result = self.tools.list_dir(path)
        elif tool_name == "search_files":
            query = args.get("query", "")
            path = args.get("path", ".")
            result = self.tools.search_files(query, path)
        else:
            result = f"Error: Unknown tool '{tool_name}'. Available: run_command, read_file, write_file, edit_file, list_dir, search_files."
        
        # Display Tool Result
        if RICH_AVAILABLE:
            res_preview = result[:1500] + ("\n... [output truncated]" if len(result) > 1500 else "")
            self.console.print(Panel(
                res_preview,
                title="🔍 OBSERVATION / RESULT",
                title_align="left",
                border_style="dim bright_black",
                padding=(0, 1)
            ))
        else:
            print(f"--- Tool Result ---\n{result[:1000]}\n-------------------")
        
        return result
    
    def send_message(self, user_input: str) -> Optional[str]:
        """Main agent message handler with autonomous execution loop"""
        self._add_to_history("user", user_input)
        
        # Display user message
        if RICH_AVAILABLE:
            timestamp = datetime.now().strftime("%H:%M:%S")
            header = Text.assemble(Text("👤 USER", style="bold bright_blue"), Text(f" [{timestamp}]", style="dim"))
            self.console.print(Panel(user_input, title=header, title_align="left", border_style="bright_blue", padding=(0, 1)))
        else:
            print(f"\n👤 USER: {user_input}")
        
        final_answer = None
        
        # Autonomous execution loop
        for step in range(1, self.max_steps + 1):
            raw_response = self._call_api()
            if not raw_response:
                break
            
            # Check for tool calls
            tool_calls = ToolCallParser.parse(raw_response) if self.autonomous_mode else []
            
            if not tool_calls:
                # No tools requested: Final response from assistant
                final_answer = raw_response
                self._add_to_history("assistant", final_answer)
                
                if RICH_AVAILABLE:
                    timestamp = datetime.now().strftime("%H:%M:%S")
                    header = Text.assemble(Text("🤖 FEATHERLESS", style="bold bright_green"), Text(f" [{timestamp}]", style="dim"))
                    try:
                        self.console.print(Panel(Markdown(final_answer), title=header, title_align="left", border_style="bright_green", padding=(0, 1)))
                    except Exception:
                        self.console.print(Panel(final_answer, title=header, title_align="left", border_style="bright_green", padding=(0, 1)))
                else:
                    print(f"\n🤖 FEATHERLESS:\n{final_answer}")
                break
            
            # Assistant requested tool calls
            # 1. Print any commentary or reasoning before the tool
            thoughts = ToolCallParser.strip_tool_blocks(raw_response)
            if thoughts:
                if RICH_AVAILABLE:
                    self.console.print(Panel(
                        Markdown(thoughts),
                        title=f"💭 THOUGHTS (Step {step}/{self.max_steps})",
                        title_align="left",
                        border_style="dim bright_cyan",
                        padding=(0, 1)
                    ))
                else:
                    print(f"\n💭 THOUGHTS [Step {step}]:\n{thoughts}")
            
            # Add assistant's tool call turn to conversation history
            self._add_to_history("assistant", raw_response)
            
            # 2. Execute each tool and collect observations
            observations = []
            for tc in tool_calls:
                tool_name = tc.get("tool", "")
                args = tc.get("args", {})
                tool_res = self.execute_tool(tool_name, args)
                observations.append(f"[Tool: {tool_name} Result]:\n{tool_res}")
            
            # 3. Add observations as user/tool turn to history for next model step
            combined_obs = "\n\n".join(observations)
            self._add_to_history("user", f"[SYSTEM OBSERVATION]:\n{combined_obs}")
        
        else:
            warn_msg = f"⚠️ Reached maximum autonomous execution limit of {self.max_steps} steps."
            if RICH_AVAILABLE:
                self.console.print(Panel(warn_msg, border_style="yellow"))
            else:
                print(warn_msg)
        
        return final_answer
    

    def heal_command(self, command: str, max_rounds: int = 5) -> bool:
        """Execute a command and autonomously self-heal any failures using Featherless AI"""
        if RICH_AVAILABLE:
            self.console.print(Panel(
                f"[bold cyan]🚀 Executing with Self-Healing:[/bold cyan] [bold yellow]{command}[/bold yellow]",
                border_style="bright_cyan"
            ))
        else:
            print(f"🚀 Executing with Self-Healing: {command}")

        for round_idx in range(1, max_rounds + 1):
            out = self.tools.run_command(command)
            exit_code = 0
            if "Exit Code: " in out:
                try:
                    exit_code = int(out.split("Exit Code: ")[1].split("\n")[0].strip())
                except Exception:
                    exit_code = 0

            if exit_code == 0 and "Traceback (most recent call last)" not in out:
                success_msg = f"✨ [SELF-HEAL COMPLETE] Command passed cleanly with Exit Code 0 on round {round_idx}!"
                if RICH_AVAILABLE:
                    self.console.print(Panel(success_msg, border_style="bright_green"))
                    self.console.print(Panel(out, title="Output", border_style="dim"))
                else:
                    print(success_msg)
                    print(out)
                return True

            heal_header = f"🩹 [SELF-HEALING ROUND {round_idx}/{max_rounds}] Command exited with code {exit_code}"
            if RICH_AVAILABLE:
                self.console.print(Panel(heal_header, border_style="yellow"))
                self.console.print(Panel(out, title="Error Traceback", border_style="red"))
            else:
                print(heal_header)
                print(out)

            heal_prompt = f"""[AUTONOMOUS SELF-HEALING REQUEST - ROUND {round_idx}/{max_rounds}]
The command `{command}` failed with exit code {exit_code}.

Command Output / Error:
{out}

TASK DIRECTIVE:
1. Inspect the error and identify the exact root cause, file, and line number.
2. Use `read_file` or `search_files` to inspect the failing code.
3. Use `edit_file` or `write_file` to fix the bug directly.
4. Run `{command}` with `run_command` to test and confirm the fix.
5. Provide a summary once the command exits with code 0."""

            self.send_message(heal_prompt)

            verify_out = self.tools.run_command(command)
            v_code = 0
            if "Exit Code: " in verify_out:
                try:
                    v_code = int(verify_out.split("Exit Code: ")[1].split("\n")[0].strip())
                except Exception:
                    v_code = 0
            if v_code == 0 and "Traceback (most recent call last)" not in verify_out:
                success_msg = f"✨ [SELF-HEAL VERIFIED] Fix successful! Command passed with Exit Code 0."
                if RICH_AVAILABLE:
                    self.console.print(Panel(success_msg, border_style="bright_green"))
                else:
                    print(success_msg)
                return True

        fail_msg = f"❌ [SELF-HEAL FAILED] Could not resolve error after {max_rounds} rounds."
        if RICH_AVAILABLE:
            self.console.print(Panel(fail_msg, border_style="red"))
        else:
            print(fail_msg)
        return False

    def run_direct_command(self, cmd_line: str):
        """Run a shell command directly without AI step"""
        if RICH_AVAILABLE:
            self.console.print(f"[bold yellow]$ {cmd_line}[/bold yellow]")
        else:
            print(f"$ {cmd_line}")
        output = self.tools.run_command(cmd_line)
        if RICH_AVAILABLE:
            self.console.print(Panel(output, border_style="dim", padding=(0, 1)))
        else:
            print(output)
    
    def clear_history(self):
        self.conversation_history = []
        if RICH_AVAILABLE:
            self.console.print(Panel("🗑️ Conversation history cleared", border_style="bright_green", padding=(0, 1)))
        else:
            print("Conversation history cleared.")
    
    def show_history(self):
        if not self.conversation_history:
            msg = "📭 No conversation history"
            if RICH_AVAILABLE:
                self.console.print(Panel(msg, border_style="dim", padding=(0, 1)))
            else:
                print(msg)
            return
        
        if RICH_AVAILABLE:
            self.console.print(Panel(f"Showing {len(self.conversation_history)} messages", title="📜 CONVERSATION HISTORY", title_align="left", border_style="bright_cyan", padding=(0, 1)))
        for msg in self.conversation_history:
            print(f"[{msg.role.upper()}]: {msg.content[:160]}...")
    
    def change_model(self, new_model: str):
        self.model = new_model
        if RICH_AVAILABLE:
            self.console.print(Panel(f"🔄 Model changed to: {new_model}", border_style="bright_green", padding=(0, 1)))
        else:
            print(f"Model changed to: {new_model}")
    
    def set_system_prompt(self, new_prompt: str):
        self.system_prompt = new_prompt
        if RICH_AVAILABLE:
            self.console.print(Panel("🔄 System prompt updated", border_style="bright_green", padding=(0, 1)))
        else:
            print("System prompt updated.")
    
    def show_tools(self):
        """Display documentation for all available tools"""
        if RICH_AVAILABLE:
            table = Table(show_header=True, header_style="bold bright_cyan", border_style="dim")
            table.add_column("Tool Name", style="bold bright_yellow", width=18)
            table.add_column("Description", style="white")
            table.add_column("Key Parameters", style="dim")
            
            table.add_row("run_command", "Run bash shell commands & capture output", "command")
            table.add_row("read_file", "Read file contents with line numbering", "path, start_line, end_line")
            table.add_row("write_file", "Create or overwrite script/file", "path, content")
            table.add_row("edit_file", "Exact string replacement in scripts", "path, old_text, new_text")
            table.add_row("list_dir", "Inspect directory contents & file sizes", "path")
            table.add_row("search_files", "Search text patterns / grep in repo", "query, path")
            
            self.console.print(Panel(table, title="🛠️ AUTONOMOUS AGENT TOOLS", title_align="left", border_style="bright_cyan", padding=(1, 1)))
        else:
            print("""
=== Available Autonomous Tools ===
1. run_command   - Run shell commands (command)
2. read_file     - Read file with lines (path, start_line, end_line)
3. write_file    - Create/overwrite file (path, content)
4. edit_file     - Replace code blocks (path, old_text, new_text)
5. list_dir      - List directory entries (path)
6. search_files  - Search text across files (query, path)
""")

    def show_help(self):
        if RICH_AVAILABLE:
            table = Table(show_header=True, header_style="bold bright_magenta", border_style="dim")
            table.add_column("Command", style="bold bright_yellow", width=22)
            table.add_column("Description", style="white")
            
            table.add_row("/auto [on|off]", "Toggle autonomous multi-step execution")
            table.add_row("/confirm [on|off]", "Toggle confirmation prompt before commands")
            table.add_row("/tools", "Display all autonomous tools and syntax")
            table.add_row("/cmd <command>", "Run shell command directly (or !<cmd>)")
            table.add_row("/ls [path]", "Quick directory listing")
            table.add_row("/read <path>", "Quick read a file")
            table.add_row("/model <id>", "Switch Featherless model")
            table.add_row("/system <prompt>", "Change system prompt")
            table.add_row("/current", "Display current configuration")
            table.add_row("/clear", "Clear session history")
            table.add_row("/exit", "Exit session")
            
            self.console.print(Panel(table, title="🪶 COMMAND REFERENCE", title_align="left", border_style="bright_cyan", padding=(1, 1)))
        else:
            print("""
=== Commands ===
/auto [on|off]     - Toggle autonomous tool execution
/confirm [on|off]  - Toggle command confirmation
/tools             - View available agent tools
/cmd <cmd> or !cmd - Run shell command directly
/ls [path]         - List files
/read <path>       - View file
/model <id>        - Change model
/clear             - Clear history
/exit              - Exit
""")

    def show_current_settings(self):
        if RICH_AVAILABLE:
            table = Table(show_header=False, border_style="dim")
            table.add_column("Setting", style="bold bright_yellow", width=22)
            table.add_column("Value", style="white")
            
            table.add_row("Model", self.model)
            table.add_row("Autonomous Mode", "ENABLED (Runs commands & edits autonomously)" if self.autonomous_mode else "DISABLED (Chat only)")
            table.add_row("Require Confirm", "YES (Prompts before each tool)" if self.require_confirm else "NO (Fully autonomous)")
            table.add_row("Max Loop Steps", str(self.max_steps))
            table.add_row("Working Directory", self.tools.work_dir)
            table.add_row("Base URL", self.base_url)
            table.add_row("History Length", f"{len(self.conversation_history)} messages")
            
            self.console.print(Panel(table, title="⚙️ CURRENT AGENT SETTINGS", title_align="left", border_style="bright_cyan", padding=(1, 1)))
        else:
            print(f"""
Model: {self.model}
Autonomous: {self.autonomous_mode}
Require Confirm: {self.require_confirm}
Max Steps: {self.max_steps}
Working Dir: {self.tools.work_dir}
""")

    def _show_welcome_screen(self):
        if RICH_AVAILABLE:
            welcome_text = Text()
            welcome_text.append("🪶 ", style="bold bright_cyan")
            welcome_text.append("FEATHERLESS", style="bold bright_cyan")
            welcome_text.append(" AUTONOMOUS AGENT", style="bold white")
            
            subtitle = Text("Autonomous Code Execution, Script Editing & Terminal Automation", style="dim italic")
            
            self.console.print()
            self.console.print(Panel(
                Align.center(welcome_text),
                title=subtitle,
                title_align="center",
                border_style="bright_cyan",
                padding=(1, 2)
            ))
            
            # Status badge panel
            status_text = Text()
            status_text.append("Model: ", style="dim")
            status_text.append(self.model, style="bold bright_magenta")
            status_text.append("  •  Mode: ", style="dim")
            status_text.append("AUTONOMOUS", style="bold bright_green" if self.autonomous_mode else "yellow")
            status_text.append("  •  Dir: ", style="dim")
            status_text.append(os.path.basename(self.tools.work_dir) or ".", style="cyan")
            
            self.console.print(Panel(
                Align.center(status_text),
                border_style="dim",
                padding=(0, 1)
            ))
            
            quick_help = Text()
            quick_help.append("Type your task • ", style="dim")
            quick_help.append("/tools", style="bold bright_yellow")
            quick_help.append(" for tool specs • ", style="dim")
            quick_help.append("/help", style="bold bright_yellow")
            quick_help.append(" for commands • ", style="dim")
            quick_help.append("/exit", style="bold bright_yellow")
            quick_help.append(" to quit", style="dim")
            
            self.console.print(Align.center(quick_help))
            self.console.print()
        else:
            print("🪶 FEATHERLESS AUTONOMOUS AGENT")
            print(f"Model: {self.model} | Autonomous Mode: {self.autonomous_mode}")
            print("Type your task, /tools, /help, or /exit")
            print("-" * 50)

    def run_interactive(self):
        self._show_welcome_screen()
        
        while True:
            try:
                if RICH_AVAILABLE:
                    prompt_label = "[bold bright_blue]👤 YOU[/bold bright_blue] [dim bright_black]›[/dim bright_black] "
                    user_input = self.console.input(prompt_label)
                else:
                    user_input = input("You: ")
                
                if not user_input.strip():
                    continue
                
                # Direct shell command shortcut !<cmd>
                if user_input.startswith("!"):
                    self.run_direct_command(user_input[1:].strip())
                    continue
                
                # Slash commands
                if user_input.startswith("/"):
                    self._handle_command(user_input)
                    continue
                
                # Send task to agent
                self.send_message(user_input)
                
            except KeyboardInterrupt:
                if RICH_AVAILABLE:
                    self.console.print(Panel("👋 Goodbye! Thanks for using Featherless Agent", border_style="bright_cyan", padding=(0, 1)))
                else:
                    print("\n👋 Goodbye! Thanks for using Featherless Agent")
                break
            except EOFError:
                break
    
    def _handle_command(self, command: str):
        parts = command.split()
        cmd = parts[0].lower()
        
        if cmd == "/help":
            self.show_help()
        elif cmd == "/heal":
            if len(parts) > 1:
                self.heal_command(" ".join(parts[1:]))
            else:
                print("Usage: /heal <command to run and fix>")
        elif cmd == "/tools":
            self.show_tools()
        elif cmd == "/clear":
            self.clear_history()
        elif cmd == "/history":
            self.show_history()
        elif cmd == "/current":
            self.show_current_settings()
        elif cmd == "/auto":
            if len(parts) > 1:
                val = parts[1].lower()
                self.autonomous_mode = val in ("on", "true", "1", "yes", "enable")
            else:
                self.autonomous_mode = not self.autonomous_mode
            status = "ENABLED" if self.autonomous_mode else "DISABLED"
            if RICH_AVAILABLE:
                self.console.print(Panel(f"🤖 Autonomous Execution: [bold]{status}[/bold]", border_style="bright_green" if self.autonomous_mode else "yellow", padding=(0, 1)))
            else:
                print(f"Autonomous Execution: {status}")
        elif cmd == "/confirm":
            if len(parts) > 1:
                val = parts[1].lower()
                self.require_confirm = val in ("on", "true", "1", "yes", "enable")
            else:
                self.require_confirm = not self.require_confirm
            status = "ENABLED (will prompt before commands)" if self.require_confirm else "DISABLED (runs autonomously)"
            if RICH_AVAILABLE:
                self.console.print(Panel(f"🛡️ Tool Confirmation: [bold]{status}[/bold]", border_style="bright_cyan", padding=(0, 1)))
            else:
                print(f"Tool Confirmation: {status}")
        elif cmd in ("/cmd", "/sh"):
            if len(parts) > 1:
                self.run_direct_command(" ".join(parts[1:]))
            else:
                print("Usage: /cmd <shell command>")
        elif cmd == "/ls":
            p = parts[1] if len(parts) > 1 else "."
            out = self.tools.list_dir(p)
            if RICH_AVAILABLE:
                self.console.print(Panel(out, border_style="dim", padding=(0, 1)))
            else:
                print(out)
        elif cmd == "/read":
            if len(parts) > 1:
                out = self.tools.read_file(parts[1])
                if RICH_AVAILABLE:
                    self.console.print(Panel(out, border_style="dim", padding=(0, 1)))
                else:
                    print(out)
            else:
                print("Usage: /read <file_path>")
        elif cmd == "/model":
            if len(parts) > 1:
                self.change_model(" ".join(parts[1:]))
            else:
                print("Usage: /model <model_id>")
        elif cmd == "/system":
            if len(parts) > 1:
                self.set_system_prompt(" ".join(parts[1:]))
            else:
                print("Usage: /system <prompt>")
        elif cmd == "/exit":
            if RICH_AVAILABLE:
                self.console.print(Panel("👋 Goodbye! Thanks for using Featherless Agent", border_style="bright_cyan", padding=(0, 1)))
            else:
                print("👋 Goodbye! Thanks for using Featherless Agent")
            sys.exit(0)
        else:
            if RICH_AVAILABLE:
                self.console.print(f"Unknown command: {cmd}. Type /help for commands.", style="red")
            else:
                print(f"Unknown command: {cmd}. Type /help for commands.")


def main():
    parser = argparse.ArgumentParser(description="Featherless Autonomous Terminal Agent")
    parser.add_argument("--api-key", help="Featherless API key (or set FEATHERLESS_API_KEY env var)")
    parser.add_argument("--base-url", default="https://api.featherless.ai/v1", help="API base URL")
    parser.add_argument("--model", default="Qwen/Qwen2.5-7B-Instruct", help="Model ID")
    parser.add_argument("--system", help="Custom system prompt")
    parser.add_argument("--prompt", "--task", "-t", dest="task", help="Execute task autonomously and exit")
    parser.add_argument("--heal", help="Run command and enter autonomous self-healing loop on error")
    parser.add_argument("--auto", action="store_true", default=True, help="Enable autonomous execution (default: True)")
    parser.add_argument("--confirm", action="store_true", default=False, help="Require confirmation before running tools")
    parser.add_argument("--max-steps", type=int, default=25, help="Maximum steps for autonomous task loop (default: 25)")
    parser.add_argument("--work-dir", default=".", help="Workspace working directory")
    
    args = parser.parse_args()
    
    agent = FeatherlessChatAgent(
        api_key=args.api_key,
        base_url=args.base_url,
        model=args.model,
        system_prompt=args.system,
        autonomous=args.auto,
        require_confirm=args.confirm,
        max_steps=args.max_steps,
        work_dir=args.work_dir
    )
    
    if args.heal:
        agent.heal_command(args.heal)
    elif args.task:
        agent.send_message(args.task)
    else:
        agent.run_interactive()


if __name__ == "__main__":
    main()
