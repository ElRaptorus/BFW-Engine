#!/usr/bin/env python3
"""Block agent writes to .git/config and .cursorignore."""

from __future__ import annotations

import json
import re
import sys

RESTORE_MARKER = "restore-protected-files"
DENY_MESSAGE = (
    "Refusing to write .git/config or .cursorignore. "
    "The Cursor sandbox can flush an empty overlay onto these files and break Git remotes. "
    "If they are already empty, run .cursor/hooks/restore-protected-files.sh with full permissions."
)

REDIRECT_PATTERN = re.compile(
    r"(?:>|tee(?:\s+-a)?)\s*['\"]?(?:\./)?(?:\.git/config|\.cursorignore)\b",
    re.IGNORECASE,
)
TRUNCATE_PATTERN = re.compile(
    r"(?:truncate|rm\s+(?:-f\s+)?)(?:\s+\S+)*\s+['\"]?(?:\./)?(?:\.git/config|\.cursorignore)\b",
    re.IGNORECASE,
)
HEREDOC_PATTERN = re.compile(
    r"cat\s+>\s*['\"]?(?:\./)?(?:\.git/config|\.cursorignore)\b",
    re.IGNORECASE,
)


def collect_strings(value: object, into: list[str]) -> None:
    if isinstance(value, str):
        into.append(value)
    elif isinstance(value, dict):
        for nested in value.values():
            collect_strings(nested, into)
    elif isinstance(value, list):
        for nested in value:
            collect_strings(nested, into)


def path_is_protected(path: str) -> bool:
    normalized = path.replace("\\", "/").rstrip("/")
    return normalized.endswith(".git/config") or normalized.endswith(".cursorignore")


def deny() -> int:
    json.dump(
        {
            "permission": "deny",
            "user_message": DENY_MESSAGE,
            "agent_message": DENY_MESSAGE,
        },
        sys.stdout,
    )
    return 0


def allow() -> int:
    json.dump({"permission": "allow"}, sys.stdout)
    return 0


def extract_command(payload: dict) -> str:
    if isinstance(payload.get("command"), str):
        return payload["command"]
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict) and isinstance(tool_input.get("command"), str):
        return tool_input["command"]
    arguments = payload.get("arguments")
    if isinstance(arguments, dict) and isinstance(arguments.get("command"), str):
        return arguments["command"]
    return ""


def extract_tool_name(payload: dict) -> str:
    for key in ("tool_name", "toolName", "tool"):
        value = payload.get(key)
        if isinstance(value, str):
            return value.lower()
    return ""


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        return allow()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return allow()
    if not isinstance(payload, dict):
        return allow()

    strings: list[str] = []
    collect_strings(payload, strings)
    blob = "\n".join(strings)
    if RESTORE_MARKER in blob:
        return allow()

    command = extract_command(payload)
    if command and (
        REDIRECT_PATTERN.search(command)
        or TRUNCATE_PATTERN.search(command)
        or HEREDOC_PATTERN.search(command)
    ):
        return deny()

    tool_name = extract_tool_name(payload)
    mutating_tools = {"write", "strreplace", "delete", "editnotebook"}
    if tool_name in mutating_tools:
        for text in strings:
            if path_is_protected(text):
                return deny()

    return allow()


if __name__ == "__main__":
    raise SystemExit(main())
