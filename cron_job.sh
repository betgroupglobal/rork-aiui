#!/usr/bin/env bash
# Periodic Featherless AI Self-Healing Error Monitor
set -e

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FEATHERLESS_API_KEY="${FEATHERLESS_API_KEY:-rc_a939625b5ebea3e527e07ee81d1d3ac10a77be72203eed6e53c3a81f4174a86a}"

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Featherless AI Self-Healing Monitor ==="
python3 "${DIR}/error_checker.py" --heal --dir "${DIR}"
echo "=== Monitor pass finished cleanly ==="
