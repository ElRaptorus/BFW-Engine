#!/usr/bin/env bash
# Denies agent writes that would truncate .git/config or .cursorignore.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/.cursor/hooks/block_protected_file_writes.py"
