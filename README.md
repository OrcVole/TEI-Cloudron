# Text Embeddings Inference for Cloudron

This repository packages [Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference)
(TEI), Hugging Face's fast Rust server for text embeddings and reranking, as a Cloudron application.
It keeps the upstream binary unmodified and adds only a Cloudron-conformant runtime: a multi-stage
Dockerfile, an entrypoint that prepares and secures the runtime, a manifest, and sane defaults.

TEI is the embedding half of a self-hostable retrieval stack: it turns text into vectors, and a
vector database such as [Qdrant](https://github.com/OrcVole/qdrant-cloudron) stores and searches
them. The two are packaged separately and pair at runtime.

Hugging Face, Text Embeddings Inference, and the names of any models are trademarks of their
respective owners. This package is community-maintained and is not affiliated with or endorsed by
Hugging Face.

## Topology

TEI serves an HTTP API and a small set of open endpoints on one port. The package splits them by
purpose on a single domain:

| Surface | Path | Behind Cloudron login | Authentication |
|---|---|---|---|
| Embedding API | `/embed`, `/v1/embeddings`, `/rerank`, `/info` | No | TEI API key (Bearer) |
| Health check | `/health` | No | None (open, for monitoring) |
| API docs (Swagger) | `/docs` | Yes (the `proxyAuth` addon, scoped to `/docs`) | Cloudron single sign-on |

The embedding endpoints carry programmatic traffic that cannot complete an interactive sign-in, so
they stay in front of Cloudron login and are protected by TEI's own API key. An unauthenticated call
therefore returns TEI's own `401`, not a redirect, which is what lets sibling apps and external
clients authenticate with the key. `/health` is open so Cloudron can monitor the app. The only
browsable surface, the interactive Swagger docs at `/docs`, sits behind Cloudron login.

## Client URLs

After install, with `<domain>` the app domain you chose:

- OpenAI-compatible embeddings: `POST https://<domain>/v1/embeddings`
- Native embeddings: `POST https://<domain>/embed`
- Health: `GET https://<domain>/health` (open)
- Swagger docs: `https://<domain>/docs` (sign in with Cloudron)

With the key as a bearer token:

```
curl https://<domain>/v1/embeddings \
  -H "Authorization: Bearer <key>" -H "content-type: application/json" \
  -d '{"input":"hello world","model":"BAAI/bge-small-en-v1.5"}'

curl https://<domain>/embed \
  -H "Authorization: Bearer <key>" -H "content-type: application/json" \
  -d '{"inputs":"hello world"}'
```

A request with no key, or the wrong key, returns `401`. For the OpenAI endpoint, send `model` as the
served model id (the default is `BAAI/bge-small-en-v1.5`) or leave it empty; an arbitrary name is
rejected.

## No web dashboard (and how to check it works)

TEI is an API server, not a web application. Opening the app domain in a browser shows a blank page,
and that is expected, not a fault. The only browsable page is the Swagger API explorer at `/docs`
(behind Cloudron login; the app's "Open" button points there). You verify it works by calling it:

- `GET /health` returns `OK` with no key (a quick "is it alive" check).
- `POST /v1/embeddings` with the key returns a JSON object whose `embedding` is a list of about 384
  decimal numbers. That array of numbers is the correct, successful output: it is the embedding (your
  text turned into coordinates), meant for a vector database to compare and search, not for a person
  to read. A `401` instead means the key is missing or wrong.

## The API key

TEI has no authentication by default: anyone who can reach it can use it. This package closes that.
On first start it generates a strong API key, stored at `/app/data/.secrets/keys.env`. To read it,
open a Terminal for the app (or `cloudron exec`) and:

```
cat /app/data/.secrets/keys.env
```

The key is injected into the server through the environment, so it never appears in the process
table. Send it as an `Authorization: Bearer` token. Unlike a database, TEI has a single access tier
(there is no read-only key): every embedding call uses the same key.

## The model

The default model is `BAAI/bge-small-en-v1.5`: 384-dimensional English embeddings, about 130 MB,
which matches the dimensionality used in the Qdrant package's retrieval example. It is downloaded on
first boot and cached under `/app/data`, so it is not re-downloaded on restart and is covered by
backup.

To serve a different model, set `TEI_MODEL_ID` in the app's Environment to any TEI-compatible model
id (see the upstream "Supported models" list) and restart. The new model downloads on the next boot.
Other tunables are exposed as environment variables: `TEI_REVISION`, `TEI_POOLING`, `TEI_DTYPE`,
`TEI_SERVED_MODEL_NAME`, `TEI_AUTO_TRUNCATE`, `TEI_HF_TOKEN` (for gated or private models), and
`TEI_NUM_THREADS`. See `docs/INTEGRATIONS.md` for worked examples.

Embeddings versus reranking: the default model does embeddings only. The `/rerank` endpoint needs a
cross-encoder (sequence-classification) model, for example `BAAI/bge-reranker-base`; set
`TEI_MODEL_ID` to one of those to serve a reranker instead.

## Memory and model size

The default memory limit is 2 GB, which comfortably fits the default model and most small or medium
embedding models. A large model needs more: raise the limit in the app's Resources settings. The
thread pool is sized to the app's CPU allotment automatically and can be overridden with
`TEI_NUM_THREADS`.

## Backup and restore

TEI holds almost no user state. The two things that matter are the generated API key and the cached
model, both under `/app/data`, which Cloudron backs up. A restore preserves the key byte-for-byte
(so existing integrators keep working) and the cached model (so the app does not re-download). There
is no database and no write-ahead log to reconcile.

## Updating

The upstream version is pinned in one canonical place, the `TEI_VERSION` build argument and the
pinned `@sha256` digest in the `Dockerfile`. `cloudron update` rebuilds and updates the app, taking a
backup first. See `docs/UPGRADING.md` for the version policy and the release gates.

## Security model

- The embedding API is protected by the TEI API key, generated on first run and injected through the
  environment.
- The interactive Swagger docs at `/docs` are protected by the Cloudron `proxyAuth` addon. It cannot
  be added after install, so it is declared from the start.
- `/health` is intentionally open (no key) so Cloudron's health check can reach it; it exposes only
  liveness, not data.
- REST runs over the Cloudron domain with Let's Encrypt TLS.

## Architecture note: amd64 only

This package targets amd64 Cloudron hosts. The upstream CPU build bundles the Intel MKL math runtime
and is published for amd64 only; there is no arm64 CPU image. See
`docs/decisions/0002-amd64-only.md`.

## Integrations

TEI's `/v1/embeddings` is a drop-in OpenAI-compatible embeddings provider for OpenWebUI, AnythingLLM,
n8n, and `rig`, and it pairs with the Qdrant package to form a self-hostable retrieval stack: TEI
embeds, Qdrant stores and searches. See `docs/INTEGRATIONS.md` for tested recipes.

## Install

This package is published as a public image and a Cloudron community versions file. To install,
point the Cloudron CLI at the versions URL and choose a domain:

```
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/TEI-Cloudron/main/CloudronVersions.json \
  --location tei.example.com
```

The image is pinned by digest in `CloudronVersions.json`, so every install pulls the exact build
that was published.

This community versions-url channel requires **Cloudron 9.1.0 or newer**: the channel mandates the
`iconUrl` manifest field, and `iconUrl` requires box 9.1.0, so a versions-url manifest cannot target
a lower floor (omitting `iconUrl` makes versions-url validation fail). On a box below 9.1.0, install
by building from source instead (next section), which works on Cloudron 8.3 and up and takes its icon
from `file://logo.png`.

## Build from source

To build the image yourself instead of pulling the published one, clone this repository and run the
Cloudron build flow (it builds on the server, so no local Docker is needed), then install:

```
cloudron install --location tei.example.com
```

See `AGENTS.md` for the packaging contract, `docs/DEBUGGING.md` for the runbook, and
`docs/RELEASING.md` for the release procedure.
