#!/bin/bash
set -euo pipefail

raw="$(cat)"
if [[ "$raw" != *"invoice_id"* ]]; then
  echo '{"error":"missing invoice_id"}' >&2
  exit 1
fi
echo '{"valid":true}'
