#!/usr/bin/env python3
"""Restore truncated Engine git config / .cursorignore from committed backups."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path


def restore_if_empty(target: Path, backup: Path, minimum_bytes: int) -> None:
    if not backup.is_file():
        return
    current_size = target.stat().st_size if target.is_file() else 0
    if current_size >= minimum_bytes:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(backup, target)


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    root = Path(sys.argv[1])
    protected = root / ".cursor" / "protected"
    restore_if_empty(root / ".git" / "config", protected / "git.config", 32)
    restore_if_empty(root / ".cursorignore", protected / "cursorignore", 16)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
