#!/bin/bash
#
# Cloudron entrypoint for Text Embeddings Inference (TEI).
#
# Runs as root, prepares /app/data, generates and persists a single API key on first run, exports
# the package-forced settings, then drops to the cloudron user and execs the router. Every
# package-emitted line is prefixed with "==>" so logs are greppable. See docs/DEBUGGING.md.

set -euo pipefail

CODE=/app/code
DATA=/app/data
BIN="${CODE}/text-embeddings-router"
SECRETS_DIR="${DATA}/.secrets"
KEYS_ENV="${SECRETS_DIR}/keys.env"
HUB_CACHE="${DATA}/hub"          # HuggingFace model cache (persistent, backed up)
HF_DIR="${DATA}/hf"             # HF_HOME: token + misc HF state (writable)
SENTINEL="${DATA}/.initialized"
VERSION="${TEI_VERSION:-unknown}"

# The model is operator-tunable via the app environment (TEI_MODEL_ID). Default ships an English
# 384-dim model that pairs dimensionally with the Qdrant package's RAG example.
DEFAULT_MODEL="BAAI/bge-small-en-v1.5"
MODEL_ID="${TEI_MODEL_ID:-${DEFAULT_MODEL}}"
HTTP_PORT="${TEI_HTTP_PORT:-8080}"

echo "==> [start] text-embeddings-inference ${VERSION} booting"

# 1. Ownership and layout. Backups/restores can reset ownership, so fix it before anything else.
#    All persistent state (model cache, HF home, the key) lives under /app/data so it is backed up.
echo "==> [start] preparing ${DATA} (model cache, hf home, secrets)"
mkdir -p "${HUB_CACHE}" "${HF_DIR}" "${SECRETS_DIR}"
chown -R cloudron:cloudron "${DATA}"
chmod 0700 "${SECRETS_DIR}"

# 2. First run only: generate the API key. TEI has a single key (no read-only tier). Never clobber
#    an existing key; it is the user's credential and integrators may have it configured.
if [[ ! -f "${KEYS_ENV}" ]]; then
  echo "==> [start] first run: generating API key"
  GEN_KEY="$(openssl rand -hex 32)"
  ( umask 077; cat > "${KEYS_ENV}" <<EOF
# Text Embeddings Inference API key generated on first run. Treat as a secret.
# TEI_API_KEY: send as "Authorization: Bearer <key>" to /embed, /v1/embeddings, /rerank, /info.
# The /health and /docs paths are open (no key required).
TEI_API_KEY=${GEN_KEY}
EOF
  )
  chown cloudron:cloudron "${KEYS_ENV}"
  chmod 0600 "${KEYS_ENV}"
  unset GEN_KEY
  echo "==> [start] API key stored at ${KEYS_ENV}"
else
  echo "==> [start] existing API key found"
fi

touch "${SENTINEL}"
chown cloudron:cloudron "${SENTINEL}"

# 3. Load the generated key, then export the package-forced settings. The key is exported as an
#    environment variable (API_KEY) rather than a --api-key CLI flag so it does not appear in the
#    process table. The router reads all of these from the environment.
# shellcheck disable=SC1090,SC1091
set -a; . "${KEYS_ENV}"; set +a

export API_KEY="${TEI_API_KEY}"
export HUGGINGFACE_HUB_CACHE="${HUB_CACHE}"
export HF_HOME="${HF_DIR}"
# Optional Hugging Face token for gated/private models (operator sets TEI_HF_TOKEN in the app env).
[[ -n "${TEI_HF_TOKEN:-}" ]] && export HF_TOKEN="${TEI_HF_TOKEN}"

# 4. Concurrency, sized to the cgroup CPU allotment Cloudron grants this app. RAYON_NUM_THREADS
#    drives the inference thread pool; tokenization workers parse/validate payloads. Both default
#    to the available CPUs and are overridable with TEI_NUM_THREADS.
CPUS="$(nproc 2>/dev/null || echo 2)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CQ CP < /sys/fs/cgroup/cpu.max || true
  if [[ "${CQ:-max}" != "max" && "${CP:-0}" -gt 0 ]]; then
    C=$(( CQ / CP )); (( C >= 1 )) && CPUS=$C
  fi
fi
THREADS="${TEI_NUM_THREADS:-${CPUS}}"
(( THREADS < 1 )) && THREADS=1
export RAYON_NUM_THREADS="${THREADS}"
export TOKENIZATION_WORKERS="${THREADS}"

# 5. Informational: log the cgroup memory limit (model RAM scales with model size).
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  echo "==> [start] cgroup memory.max=$(cat /sys/fs/cgroup/memory.max) bytes"
fi

# 6. Assemble the argument vector. --hostname and --port are passed on the command line because the
#    container's HOSTNAME env is set by the platform to the container id (which would make the
#    router bind the wrong interface), and the port must be deterministic for the Cloudron proxy.
ARGS=( --model-id "${MODEL_ID}" --hostname 0.0.0.0 --port "${HTTP_PORT}" )
[[ -n "${TEI_REVISION:-}" ]]           && ARGS+=( --revision "${TEI_REVISION}" )
[[ -n "${TEI_POOLING:-}" ]]            && ARGS+=( --pooling "${TEI_POOLING}" )
[[ -n "${TEI_DTYPE:-}" ]]              && ARGS+=( --dtype "${TEI_DTYPE}" )
[[ -n "${TEI_SERVED_MODEL_NAME:-}" ]]  && ARGS+=( --served-model-name "${TEI_SERVED_MODEL_NAME}" )
[[ -n "${TEI_AUTO_TRUNCATE:-}" ]]      && ARGS+=( --auto-truncate "${TEI_AUTO_TRUNCATE}" )

# 7. Report resolved runtime facts (never the key) and hand off.
echo "==> [start] model    : ${MODEL_ID}${TEI_REVISION:+ @ ${TEI_REVISION}}"
echo "==> [start] http     : 0.0.0.0:${HTTP_PORT} (/embed, /v1/embeddings; /health and /docs are open)"
echo "==> [start] cache    : ${HUB_CACHE} (first boot downloads the model here)"
echo "==> [start] hf_home  : ${HF_DIR}"
echo "==> [start] threads  : ${THREADS} (rayon + tokenization)"
echo "==> [start] api key  : $( [[ -s "${KEYS_ENV}" ]] && echo 'present' || echo 'MISSING' )"
echo "==> [start] exec text-embeddings-router ${VERSION}"
exec gosu cloudron:cloudron "${BIN}" "${ARGS[@]}"
