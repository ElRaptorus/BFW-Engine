#!/usr/bin/env bash
#
# Mint a signed HS256 JWT for local development and API testing.
# No Elixir required — uses only bash, openssl, and base64.
#
# Usage:
#   ./scripts/mint-token.sh                          # default dev-user / admin / 24h
#   ./scripts/mint-token.sh '{"sub":"op-1","lane:default":"write"}'   # clerk
#   ./scripts/mint-token.sh '{"observe_all":true}'                    # observer
#   # Lane values MUST be "read" or "write" — boolean true grants nothing.
#   TDE_JWT_HS256_SECRET=my-secret ./scripts/mint-token.sh
#
# The output is a single JWT string, ready for:
#   curl -H "Authorization: Bearer $(./scripts/mint-token.sh)" http://localhost:4000/stats

set -euo pipefail

SECRET="${TDE_JWT_HS256_SECRET:-BloodForTheBloodGod!_SkullsForTheSkullThrone!}"

NOW=$(date +%s)
EXP=$(( NOW + ${TDE_TOKEN_EXP_SECONDS:-86400} ))

# Default claims; merge with user-supplied JSON if provided.
DEFAULT_CLAIMS="{\"sub\":\"dev-user\",\"roles\":[\"admin\"],\"groups\":[],\"iat\":${NOW},\"exp\":${EXP}}"

if [ $# -ge 1 ]; then
  # Merge: user claims override defaults. Requires python3 or jq.
  if command -v python3 &>/dev/null; then
    CLAIMS=$(python3 -c "
import json, sys
base = json.loads(sys.argv[1])
override = json.loads(sys.argv[2])
base.update(override)
# Ensure iat/exp are always present
base.setdefault('iat', $NOW)
base.setdefault('exp', $EXP)
print(json.dumps(base, separators=(',', ':')))
" "$DEFAULT_CLAIMS" "$1")
  elif command -v jq &>/dev/null; then
    CLAIMS=$(echo "$DEFAULT_CLAIMS" | jq -c --argjson o "$1" '. * $o')
  else
    echo "Error: custom claims require python3 or jq for JSON merge" >&2
    exit 1
  fi
else
  CLAIMS="$DEFAULT_CLAIMS"
fi

# Base64url encode (no padding)
b64url() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

HEADER='{"alg":"HS256","typ":"JWT"}'
HEADER_B64=$(printf '%s' "$HEADER" | b64url)
PAYLOAD_B64=$(printf '%s' "$CLAIMS" | b64url)

SIGNATURE=$(printf '%s.%s' "$HEADER_B64" "$PAYLOAD_B64" \
  | openssl dgst -sha256 -hmac "$SECRET" -binary \
  | b64url)

echo "${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE}"
