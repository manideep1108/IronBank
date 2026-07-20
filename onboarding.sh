#!/usr/bin/env bash
# IronBank onboarding is implemented in onboarding.py (one script, every
# platform: Windows / macOS / Linux). This shim just forwards to it so the
# familiar `./onboarding.sh` still works on Unix-likes and Git Bash.
#
# On Windows, run it directly instead:  python onboarding.py
set -euo pipefail
cd "$(dirname "$0")"

# Find a Python that actually runs. On Windows, `python` can resolve to the
# Microsoft Store stub (opens a browser, exits non-zero) — so test each candidate.
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
    exec "$cand" onboarding.py "$@"
  fi
done

echo "python3 is required. Install it from https://www.python.org/downloads/ (on Windows, tick 'Add python.exe to PATH')." >&2
exit 1
