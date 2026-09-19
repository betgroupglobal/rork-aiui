# 🪶 Featherless AI Self-Healing Error Fixer

This repository contains autonomous self-healing tools powered by **Featherless.ai**.

## Capabilities

1. **Autonomous Self-Healing Command Runner**:
   Runs any command or script. If an error occurs, Featherless AI analyzes the traceback, inspects the failing file, edits the code, and re-executes until the command succeeds with Exit Code 0:
   ```bash
   python3 featherless-chat.py --heal "python3 your_script.py"
   # or with global feather CLI
   feather --heal "npm test"
   ```

2. **Workspace Syntax Scanner & Auto-Healer**:
   Scans all Python and JSON files in the workspace for compilation errors and automatically repairs them:
   ```bash
   python3 error_checker.py --heal
   ```

3. **Autonomous Interactive Agent**:
   Full terminal agent with autonomous tool execution:
   ```bash
   python3 featherless-chat.py
   ```
   Inside the chat, use `/heal <command>` to run and heal any failing process.

4. **Background / Cron Job**:
   ```bash
   bash cron_job.sh
   ```
