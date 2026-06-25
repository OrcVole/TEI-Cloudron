#!/bin/bash
#
# Shared helpers for the live box tests (backup-restore and upgrade). Source this file.
#
# Required environment:
#   TEI_BASE   full base URL, for example https://tei.example.com
#   TEI_KEY    API key (from /app/data/.secrets/keys.env on the app)
#
# Unlike a database, TEI holds almost no user state: the precious things that must survive a backup,
# restore, or update are (1) the generated API key, byte-for-byte, so existing integrators keep
# working, and (2) the cached model, so the app does not re-download on every restore. These helpers
# assert exactly that. There is no "seed" step because TEI does not persist user-written records;
# the model is the payload, and it is asserted by serving a deterministic-shape embedding.

EMB_MODEL="${TEI_MODEL_ID:-BAAI/bge-small-en-v1.5}"
EXPECT_DIMS="${TEI_EXPECT_DIMS:-384}"   # bge-small-en-v1.5 is 384-dim; override for another model

# embed_dims <key> — echo the embedding dimensionality returned for a fixed input, or empty on error.
embed_dims() {
  local key="${1:-${TEI_KEY}}"
  curl -fsS -X POST "${TEI_BASE}/embed" \
    -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
    -d '{"inputs":"backup restore canary"}' \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin)[0]))' 2>/dev/null
}

# verify_serving <expected-key>
# Confirms the app serves embeddings of the expected dimensionality and that the given key (the one
# generated before the backup) still authenticates after the restore, and that a wrong key is
# refused. Returns non-zero on any mismatch.
verify_serving() {
  local expected_key="${1:-${TEI_KEY}}" ok=0 dims health wrong

  health="$(curl -fsS -o /dev/null -w '%{http_code}' "${TEI_BASE}/health")"
  dims="$(embed_dims "${expected_key}")"
  wrong="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${TEI_BASE}/embed" \
    -H 'Authorization: Bearer definitely-the-wrong-key' \
    -H 'content-type: application/json' -d '{"inputs":"x"}')"

  printf '  /health: %s | embed dims: %s | wrong-key: %s\n' "${health}" "${dims:-MISSING}" "${wrong}"

  [ "${health}" = 200 ]          || { echo "  MISMATCH: /health expected 200"; ok=1; }
  [ "${dims}" = "${EXPECT_DIMS}" ] || { echo "  MISMATCH: expected ${EXPECT_DIMS}-dim embeddings"; ok=1; }
  [ "${wrong}" = 401 ]           || { echo "  MISMATCH: wrong key should return 401"; ok=1; }
  return "${ok}"
}

# assert_key_byte_equal <key-before> <key-after>
# The whole point of the backup test: the restored key must be identical to the pre-backup key, so
# clients configured with the old key keep working without rotation.
assert_key_byte_equal() {
  if [ "$1" = "$2" ] && [ -n "$1" ]; then
    echo "  key byte-equal across backup/restore: yes"
    return 0
  fi
  echo "  MISMATCH: restored key differs from the pre-backup key"
  return 1
}
