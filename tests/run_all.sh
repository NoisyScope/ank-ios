#!/usr/bin/env bash
# Runs every simulator test. Needs scripts/setup.sh to have run. Stops at the first failing suite.
set -euo pipefail
cd "$(dirname "$0")"
PY=../build/anki/out/pyenv/bin/python
"$PY" web_test.py
"$PY" custom_study_test.py
"$PY" deck_test.py
"$PY" add_card_test.py
"$PY" package_test.py
"$PY" kill_test.py
"$PY" sync_test.py
"$PY" sync_safety_test.py
"$PY" undo_test.py
"$PY" offline_test.py
"$PY" import_test.py
"$PY" scale_test.py "$@"
