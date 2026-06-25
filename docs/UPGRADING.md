# Upgrading

How to move this package to a new upstream TEI version, safely and repeatably.

TEI is a stateless inference server (its only persistent state is the generated key and a
re-downloadable model cache), so an upstream bump carries less data risk than a database, but the
build is more involved than a single binary because of the MKL runtime. Read this before changing
the pin.

## Version policy

- The upstream version is pinned in exactly one canonical place: the `TEI_VERSION` build argument and
  the pinned `@sha256` digest on the upstream `FROM` line in `Dockerfile` (both move together). The
  manifest mirrors it in `upstreamVersion`.
- Never use a floating tag. Never use the bare `:1.9`/`:latest` tags: those are CUDA images. The CPU
  build is the `cpu-` prefixed tag, pinned by digest.
- The package `version` in the manifest is our own semver and moves independently. Bump it on every
  published change.

## Current pin

- Upstream: `cpu-1.9`, `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9@sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07` (binary reports 1.9.3).
- Base: `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`.

## Minimum box version

The package declares `minBoxVersion 9.1.0`. This is the floor of the community versions-url install
channel, not of the software. The channel requires the `iconUrl` manifest field, and `iconUrl`
requires box 9.1.0 (a versions-url manifest without `iconUrl` fails validation), so there is no
8.3.0-compatible versions-url manifest. The TEI binary and `cloudron/base:5.0.0` run on Cloudron 8.3
and up; to install on a box below 9.1.0, build from source on the server (`cloudron install` from a
clone of this repository), which uses the `file://logo.png` icon and does not require `iconUrl`.

## Release gates (run on every version bump, no exceptions)

### Gate 1: the MKL runtime copy and linkage (build-time + runtime)

The Dockerfile copies the binary and the MKL runtime out of the upstream image (docs/decisions/0001).
On a bump, the file layout can change. Re-verify:

- The binary path (`/usr/local/bin/text-embeddings-router`), `libfakeintel.so`, the
  `/usr/local/lib/libmkl_*.so` set, and the `libiomp5.so` symlink target are all still present in the
  new image (the Dockerfile's gather step lists them).
- The build-time linkage gate passes (`ldd` resolves every direct dependency on `cloudron/base`,
  `--version` runs). This does NOT exercise the dlopened MKL libraries.
- `test/smoke.sh` passes: it builds the image and asserts an actual `/embed` call returns a vector on
  `cloudron/base`, which is the real test of the MKL load path. This is the gate that matters most.

### Gate 2: update survival (real `cloudron update`)

The API key and the cached model must survive an update. Verified at this pin: with the key and model
in place, `cloudron update` (which takes a pre-update backup automatically) preserved the key
byte-for-byte (`start.sh` logs `existing API key found`), loaded the model from cache rather than
re-downloading, and served embeddings with the surviving key. Re-confirm on every bump.

### Gate 3: serve and auth on a throwaway

Install the new pin on a throwaway, confirm: the app passes the health check (model download fits the
grace), `/health` is open 200, `/embed` is 401 without the key and serves the expected dimensionality
with it, and `/docs` redirects to Cloudron login. For the OpenAI surface, confirm `/v1/embeddings`
returns the expected shape.

## Standard bump steps

1. Confirm the new stable CPU tag exists upstream and resolve its digest with
   `skopeo inspect --format '{{.Digest}}' docker://ghcr.io/huggingface/text-embeddings-inference:cpu-<new>`.
   Confirm the binary version with `--version` (it may differ from the tag, as `cpu-1.9` reports
   1.9.3).
2. Change the version in the canonical places:
   - `Dockerfile`: `ARG TEI_VERSION=<new>` and the pinned `@sha256:` digest on the upstream `FROM`
     line (both must move together).
   - `CloudronManifest.json`: `upstreamVersion` to the binary version, and bump the package `version`.
3. Run Gate 1 (build, linkage, and `test/smoke.sh`), then Gates 2 and 3 on a throwaway.
4. Add a `[x.y.z]` entry to `CHANGELOG.md` and update docs/PACKAGING-NOTES.md.
5. Follow docs/RELEASING.md to build, push, pin the digest, and publish.

## What to watch for in upstream changes

- **Flags and env vars:** the package sets `MODEL_ID`, `API_KEY`, `HUGGINGFACE_HUB_CACHE`, `HF_HOME`,
  `--hostname`, `--port`, and the thread counts. Re-verify these names against the new version's
  `--help`.
- **Image layout:** the multi-stage copy depends on `/usr/local/bin/text-embeddings-router`,
  `/usr/local/libfakeintel.so`, `/usr/local/lib/libmkl_*.so`, and `/lib/x86_64-linux-gnu/libiomp5.so`.
  Re-verify on a major image change (docs/decisions/0001).
- **Default port / HOSTNAME behaviour:** the package moves the listener to 8080 and forces
  `--hostname 0.0.0.0` (docs/decisions/0003). Re-check if upstream changes its networking defaults.
- **OpenAI endpoint shape:** `/v1/embeddings` request/response. Re-check if upstream changes it.
