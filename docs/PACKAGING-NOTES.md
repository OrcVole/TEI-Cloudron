# Packaging notes (running log)

Hard-won, verified learnings from packaging Text Embeddings Inference (TEI) for Cloudron. Each entry
says what was verified empirically versus assumed. This is the source for the forum write-up.

## Pinned facts

- Upstream image: `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9@sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07`. The binary reports version `1.9.3`. **amd64 only** (the CPU build bundles Intel MKL; there is no arm64 CPU image, so the manifest list's `unknown/unknown` is only a provenance attestation, not a usable arm64 platform).
- Base image: `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c` (Ubuntu 24.04, glibc 2.39).
- The bare `:1.9` and `:latest` tags are CUDA images. The CPU build is the `cpu-` prefixed tag. Easy and costly to get wrong.
- Single source of the upstream version: the `TEI_VERSION` build argument plus the pinned digest in `Dockerfile`. The manifest mirrors it in `upstreamVersion`.

## Phase 0 and 1 (the container) — verified empirically (podman build and run on amd64)

### The MKL runtime copy (the hard part)

Unlike a single-binary package, TEI's CPU build is a binary plus an Intel MKL math runtime. `ldd` on
`text-embeddings-router` shows it needs `libstdc++`, `libssl`/`libcrypto`, `libgcc_s`, `libm`, `libc`
(all present on `cloudron/base`), plus `libiomp5.so` and a preloaded `libfakeintel.so`. The MKL
libraries themselves (`/usr/local/lib/libmkl_*.so`, about 320 MB) are dlopened at inference time and
are not DT_NEEDED of the binary.

- The non-obvious trap: `/lib/x86_64-linux-gnu/libiomp5.so` in the upstream image is a symlink to
  `../llvm-14/lib/libomp.so.5`, and that file's internal soname is `libomp.so.5`, not `libiomp5.so`.
  If you let `ldconfig` index it, a DT_NEEDED of `libiomp5.so` resolves to the wrong name and fails.
  The fix that works: `cp -L` it into a concrete file named `libiomp5.so` and resolve it at runtime
  through `LD_LIBRARY_PATH=/usr/local/lib` (filename match), not ldconfig. Verified: `ldd` on the
  final image resolves `libiomp5.so => /usr/local/lib/libiomp5.so`.
- The Dockerfile copies, from the upstream image: the binary, `libfakeintel.so`, all of
  `/usr/local/lib/*.so*` (the MKL libs), and the dereferenced `libiomp5.so`. It then keeps the
  upstream runtime env (`LD_PRELOAD=/usr/local/libfakeintel.so`, `LD_LIBRARY_PATH=/usr/local/lib`,
  `MKL_ENABLE_INSTRUCTIONS=AVX512_E4`). No `apt-get install` is needed: the base already provides
  every standard library the binary links.
- The build-time linkage gate proves the DIRECT deps resolve and `--version` runs, but it does NOT
  exercise the dlopened MKL libs. Reaching the router's `Ready` log line is the real proof, because
  `Ready` prints only after a warmup inference pass through MKL. `test/smoke.sh` asserts an actual
  `/embed` call returns a real vector on the assembled `cloudron/base` image.

### Runtime, ports, and the HOSTNAME trap

- The upstream default port is 80. The `cloudron` user cannot bind privileged ports, so the package
  moves the listener to 8080 (`--port`, passed on the command line).
- `--hostname` defaults to the `HOSTNAME` environment variable, and Docker/Cloudron set `HOSTNAME`
  to the container id. Left alone, the router would try to bind that as an interface. The package
  passes `--hostname 0.0.0.0` explicitly on the command line to override the env default. Verified
  from `--help`, which showed `[env: HOSTNAME=<container-id>]` captured at runtime.
- TEI writes nothing to its working directory: the model cache is redirected to `/app/data`, `HF_HOME`
  to `/app/data/hf`, and its internal Unix socket is under `/tmp`. So, unlike the Qdrant package, no
  `/run` working-directory shim is needed.

### Auth topology — verified on the assembled image

With `API_KEY` set: `/health` returns 200 with no auth (so it is a valid health check path),
`/embed` and `/v1/embeddings` and `/info` return 401 without the key and 200 with it, a wrong key
returns 401, `/docs` returns a 303 (Swagger redirect, open at the app layer), `/metrics` returns 200,
and `/rerank` returns 424 on the default model (it is an embedding model, not a cross-encoder; rerank
needs a reranker model). The key is injected through the `API_KEY` env var, not a `--api-key` flag,
so it never appears in the process table.

### Model and cold start

Default model `BAAI/bge-small-en-v1.5` (384-dim, ~130 MB). First boot downloads it into
`/app/data/hub`; a restart against the cached copy reaches `Ready` in a few seconds (no re-download).
Local cold start was about 21 s (metadata + ONNX weights + warmup).

## Phase 2 (live box) — verified on a throwaway (tei-testing)

On-server build (`cloudron install --location tei-testing... --memory-limit 2G`) succeeded and the
app passed Cloudron's health check on first install. Notes:

- **On-server build needs no prebuilt image.** The CLI reported "No build detected. This package will
  be built on the server" and built the Dockerfile server-side. For this path the manifest must NOT
  carry a bogus `dockerImage` digest; the test used a staging manifest with `dockerImage` removed.
- **Model download fits the health grace.** On the box the default model downloaded in about 9 s
  (1 s metadata + 7 s ONNX weights) and the server was `Ready` about 10 s after start, well inside
  Cloudron's health-check window. A LARGE model would take longer; document raising resources and
  expect a slower first boot. The thread pool auto-sized to the box's CPU allotment (12) and the
  cgroup memory limit was read as 2 GB.
- **Live topology confirmed through Cloudron's TLS proxy:** `/health` 200 open; `/embed` 401 without
  the key; `/v1/embeddings` with the key returns 384-dim vectors; `/docs` returns 302 to
  `/login?redirect=/docs` (Cloudron single sign-on).

### proxyAuth on /docs, and the supportsBearerAuth finding

The interactive Swagger docs are the only browsable surface, so the package scopes `proxyAuth` to
`/docs`. Two things verified on the box:

- **Swagger still works behind the wall.** The OpenAPI spec is served at `/api-doc/openapi.json`,
  which is OPEN (200, no auth), and the UI assets under `/docs/*` load with the Cloudron SSO cookie.
  So a logged-in user's Swagger page renders and its spec fetch succeeds. The wall on `/docs` does
  not break the docs.
- **Drop `supportsBearerAuth` on a docs-only wall.** With `proxyAuth.supportsBearerAuth: true`, a
  request carrying ANY `Authorization: Bearer <anything>` header skipped the SSO login on `/docs`
  (it returned the app's 303 instead of a 302 to `/login`). That flag is meant for a proxyAuth path
  that also hosts a Bearer-authenticated API; `/docs` does not (TEI's Bearer API lives on the open
  plane, not under `/docs`), so the flag only weakens the wall. Removed it; the canonical manifest
  scopes `proxyAuth` to `{ "path": "/docs" }` with no bearer passthrough.

## minBoxVersion and iconUrl

Same finding as the Qdrant package: the community versions-url install channel requires the `iconUrl`
manifest field, and `iconUrl` requires `minBoxVersion` at least 9.1.0 (a versions-url manifest
without `iconUrl` fails validation). So the canonical manifest declares `minBoxVersion 9.1.0` and
`iconUrl`. The software itself runs on Cloudron 8.3 and up (base 5.0.0): to install on a box below
9.1.0, build from source on the server, which validates a looser schema and does not need `iconUrl`.
The on-server build test here used `minBoxVersion 8.3.0` in the staging manifest to reflect that.

## Phase 3 (update survival) — verified on the throwaway

`cloudron update` (which automatically took a 64 MB pre-update backup, confirming the model cache is
under `/app/data` and is backed up) preserved everything: the API key was byte-identical to before
the update (`start.sh` logged `existing API key found`, so it did not reseed), the model loaded from
the cache rather than re-downloading (artifacts read in 557 µs, `Ready` in about 3 s versus 7 s on a
cold download), and the app served 384-dim embeddings with the surviving key. The update also applied
the `proxyAuth` manifest fix and re-verified on the box that a bogus bearer header now gets a 302 to
login on `/docs`.

## Phase 5 (integration) — TEI + Qdrant round trip verified live

The flagship integration was run end to end against the packaged apps on the box: TEI embedded three
documents (384-dim) through `/embed`, the vectors were stored in a throwaway Qdrant collection (size
384, Cosine) over Qdrant's REST API with its admin key, a query was embedded by TEI and searched in
Qdrant, and the correct document came back on top (the "memory safety" query returned the Rust
document at score 0.736, ahead of unrelated documents at 0.46 and 0.41). The throwaway collection was
deleted afterwards; the production Qdrant's own collections were never touched (it had none, and had
none after). The runnable recipe is `config/examples/tei_qdrant_roundtrip.py`, and the curl form is
in `docs/INTEGRATIONS.md`. Sibling recipes that require configuring the other app (OpenWebUI, n8n,
rig, agentgateway) are verified at the TEI boundary (the `/v1/embeddings` call they make works) and
shipped as documented configuration.

## What is verified versus assumed (so far)

- Verified live on a throwaway: the MKL build links and serves on `cloudron/base`; the auth topology;
  on-server install; first-install health pass; the default-model download time on the box; the
  proxyAuth/docs behaviour and the supportsBearerAuth side effect (found and fixed); cgroup-aware
  threads and memory; update survival (key byte-equal, model cache persistence); the TEI + Qdrant
  retrieval round trip.
- Not yet verified at the time of writing: backup/restore key-byte-equality via `cloudron clone`, and
  the four stranger-path publish gates. See STATUS.md for the live state.
