#!/usr/bin/env bash
# Restores .git/config and .cursorignore if a sandbox overlay truncated them.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/.cursor/hooks/restore_protected_files.py" "$root"
echo '{}'
