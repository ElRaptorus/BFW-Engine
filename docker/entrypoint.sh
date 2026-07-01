#!/usr/bin/env bash
# Thin entrypoint that runs migrations + partition pre-creation before
# starting the release. Operators who prefer to run these as separate
# deploy steps can bypass this script by overriding ENTRYPOINT.
#
# Referenced from docker/Dockerfile's ENTRYPOINT-as-release pattern is
# the default; this script is provided for the "migrate-on-start"
# deployment pattern.
set -euo pipefail

RELEASE=/app/bin/evil_engine

echo "[entrypoint] Running migrations…"
"${RELEASE}" eval "EvilEngine.Persistence.Release.migrate()"

echo "[entrypoint] Pre-creating audit-log partitions…"
"${RELEASE}" eval "EvilEngine.Persistence.Release.ensure_partitions()"

echo "[entrypoint] Starting release…"
exec "${RELEASE}" "${@:-start}"
