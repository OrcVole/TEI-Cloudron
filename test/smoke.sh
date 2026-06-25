#!/bin/bash
#
# Local container-level smoke test for the TEI Cloudron package. No Cloudron box required: it builds
# the image and runs it the way Cloudron does (root entrypoint -> start.sh -> gosu cloudron), then
# asserts the auth topology and that inference actually runs on cloudron/base.
#
# This captures the empirical proof done during initial packaging (2026-06-25): the multi-stage MKL
# copy links and the model serves real vectors through the real start.sh. Re-run it on any change to
# the Dockerfile, start.sh, or the upstream pin.
#
# Usage:  test/smoke.sh            (uses podman; set ENGINE=docker to override)
# Needs:  python3 (for JSON asserts), a working container engine, network (first run downloads ~130MB)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ENGINE="${ENGINE:-podman}"
IMG=tei-cloudron:smoke
NAME=tei-smoke-$$
PORT=18099
DATADIR="$(mktemp -d)"
fail=0
note() { printf '  %-30s %s\n' "$1" "$2"; }

cleanup() {
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  # Files under $DATADIR are owned by the in-container cloudron uid (mapped to a subuid the host
  # user cannot remove directly), so clear them from inside a throwaway container as root first.
  "$ENGINE" run --rm -v "$DATADIR":/d:Z "$IMG" sh -c 'rm -rf /d/* /d/.[!.]* /d/..?*' >/dev/null 2>&1
  rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "== build =="
"$ENGINE" build -t "$IMG" -f Dockerfile . >/dev/null 2>&1 || { echo "BUILD FAILED"; exit 1; }
echo "  build ok"

echo "== run (Cloudron-style: root -> start.sh -> gosu cloudron) =="
"$ENGINE" run -d --name "$NAME" -v "$DATADIR":/app/data:Z -p 127.0.0.1:$PORT:8080 "$IMG" >/dev/null 2>&1
ready=0
for i in $(seq 1 90); do
  "$ENGINE" logs "$NAME" 2>&1 | grep -q 'Ready' && { ready=1; break; }
  "$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -q "^$NAME$" || { echo "  CONTAINER EXITED EARLY"; "$ENGINE" logs "$NAME" 2>&1 | tail -20; exit 1; }
  sleep 2
done
[ "$ready" = 1 ] && note "ready:" "yes (~$((i*2))s)" || { echo "  NEVER became ready"; exit 1; }

# Dropped privileges?
u="$("$ENGINE" exec "$NAME" sh -c 'ps -o user= -C text-embeddings-router' 2>/dev/null | head -1 | tr -d ' ')"
note "runs as:" "$u"; [ "$u" = cloudron ] || { echo "  EXPECTED cloudron user"; fail=1; }

# Read the generated key as root inside the container (.secrets is 0700 cloudron).
KEY="$("$ENGINE" exec "$NAME" cat /app/data/.secrets/keys.env 2>/dev/null | grep -oP 'TEI_API_KEY=\K.*')"
note "key length:" "${#KEY} (expect 64)"; [ "${#KEY}" = 64 ] || fail=1

B="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

h=$(code "$B/health");                                                        note "/health no-auth:" "$h"; [ "$h" = 200 ] || fail=1
e=$(code -X POST "$B/embed" -H 'content-type: application/json' -d '{"inputs":"x"}'); note "/embed no-auth:" "$e"; [ "$e" = 401 ] || fail=1
w=$(code -X POST "$B/embed" -H "Authorization: Bearer WRONG" -H 'content-type: application/json' -d '{"inputs":"x"}'); note "/embed wrong-key:" "$w"; [ "$w" = 401 ] || fail=1

dims="$(curl -s -X POST "$B/embed" -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"inputs":"the quick brown fox"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)[0]))' 2>/dev/null)"
note "/embed keyed dims:" "${dims:-FAIL}"; [ -n "$dims" ] && [ "$dims" -gt 0 ] || fail=1

odims="$(curl -s -X POST "$B/v1/embeddings" -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"input":"hello","model":"BAAI/bge-small-en-v1.5"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null)"
note "/v1/embeddings dims:" "${odims:-FAIL}"; [ -n "$odims" ] && [ "$odims" -gt 0 ] || fail=1

echo
if [ "$fail" = 0 ]; then echo "SMOKE: PASS"; else echo "SMOKE: FAIL"; fi
exit "$fail"
