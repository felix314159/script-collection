#!/usr/bin/env bash
# genesis_time.sh — print Genesis Time from a Dora explorer instance
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "error: missing devnet name" >&2
    echo "usage: $(basename "$0") <devnet-name>" >&2
    echo "example: $(basename "$0") bal-devnet-6" >&2
    exit 1
fi

NETWORK="$1"
URL="https://dora.${NETWORK}.ethpandaops.io/"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

http_code=$(curl -sSL --max-time 30 -o "$tmp" -w '%{http_code}' "$URL" || echo "000")

if [[ "$http_code" == "503" ]]; then
    echo "devnet $NETWORK is not live anymore (HTTP 503 from $URL)" >&2
    exit 1
fi

if [[ "$http_code" == "404" ]]; then
    echo "devnet $NETWORK has not started yet (HTTP 404 from $URL)" >&2
    exit 1
fi

if [[ "$http_code" =~ ^0+$ ]]; then
    echo "could not resolve $URL — is '$NETWORK' a typo?" >&2
    exit 1
fi

if [[ "$http_code" != 2* ]]; then
    echo "error: failed to fetch $URL (HTTP $http_code)" >&2
    exit 1
fi

ts=$(grep -oE 'data-genesis-timestamp="[0-9]+"' "$tmp" \
    | head -n1 \
    | grep -oE '[0-9]+')

if [[ -z "${ts:-}" ]]; then
    echo "error: could not find Genesis Time on $URL" >&2
    exit 1
fi

now=$(date -u +%s)
diff=$((now - ts))

if (( diff < 0 )); then
    age="in the future"
elif (( diff < 60 )); then
    age="${diff} seconds ago"
elif (( diff < 3600 )); then
    age="$((diff / 60)) minutes ago"
elif (( diff < 86400 )); then
    age="$((diff / 3600)) hours ago"
else
    age="$((diff / 86400)) days ago"
fi

echo "unix: $ts"
echo "utc:  $(date -u -d "@$ts" '+%Y-%m-%d %H:%M:%S %Z')"
echo "age:  devnet launch was $age"