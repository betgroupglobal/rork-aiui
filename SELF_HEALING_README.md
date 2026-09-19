# 🪶 Featherless AI Self-Healing Error Fixer

Autonomous, closed-loop error detection and self-repair system powered by the **Featherless.ai** inference API.

---

## 🚀 Key Features

- **Automated Diagnostic Engine (`error_checker.py`)**:
  - Python AST syntax & compilation validation.
  - JSON structure and schema validation.
  - Bash/Shell syntax verification (`bash -n`).
  - JavaScript syntax checks (`node --check`).
  - Runtime command error extraction and stack trace analysis.
- **Featherless LLM Self-Healing Loop (`error_fixer.py`)**:
  - Automatically queries Featherless AI (`Qwen/Qwen2.5-Coder-32B-Instruct`, `Qwen/Qwen2.5-7B-Instruct`, etc.).
  - Generates exact repaired code, safe backups (`.bak`), and verifies fixes immediately.
  - Multi-attempt iterative healing until 0 errors remain.
- **Multiple Operational Modes**:
  - **Scan & Fix**: Detects and fixes all errors across the workspace.
  - **Command Self-Healing**: Runs any command or test suite, catches errors, and heals offending files.
  - **Continuous Watchdog**: Monitors files in real time and automatically heals errors as they are saved.
  - **Cron / Daemon Execution**: Periodic headless healing runs with structured log files.

---

## 🛠️ Usage Guide

### 1. Run Workspace Scan & Auto-Fix
Scan the current workspace and repair any detected syntax/format errors:
```bash
python3 error_fixer.py
# or using the launcher:
./feather-heal
```

### 2. Heal a Specific File
```bash
./feather-heal --file path/to/broken_script.py
```

### 3. Command / Test Suite Self-Healing
Run a command or test script, catch runtime exceptions, and automatically patch the offending code until clean:
```bash
./feather-heal --run "python3 main.py"
```

### 4. Continuous Real-Time Watchdog
Monitor files and heal any errors immediately as you develop:
```bash
./feather-heal --watch
```

### 5. Headless / Cron Setup
Run periodically via cron (`cron_job.sh`) to keep the repository healthy:
```bash
crontab -e
# Run every hour:
0 * * * * /bin/bash /Users/adminuser/AIUIRO-216/cron_job.sh
```

---

## ⚙️ Configuration & Environment

| Variable | Description | Default |
|---|---|---|
| `FEATHERLESS_API_KEY` | Featherless API Key | Built-in fallback |
| `FEATHERLESS_MODEL` | LLM model used for code diagnosis and healing | `Qwen/Qwen2.5-Coder-32B-Instruct` |
| `--max-iterations` | Max fix attempts per file | `5` |
| `--log-file` | Path to append logs | `logs/self_healing.log` |
