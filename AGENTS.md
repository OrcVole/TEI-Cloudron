# AGENTS.md

This file is the working contract for any AI agent or human who edits this repository. Read it
fully before changing anything. It encodes decisions that are already settled, so that you do not
relitigate them and do not regress conformance.

If you are an AI agent: treat the rules in "Golden rules" as hard constraints. When a request
conflicts with them, stop and surface the conflict rather than working around it.

This repository packages **Text Embeddings Inference** (https://github.com/huggingface/text-embeddings-inference,
Apache-2.0, a text embedding and reranking server written in Rust by Hugging Face) as a
**Cloudron-conformant application**. The goals, in order: (1) it runs cleanly and securely on
Cloudron, (2) the repository is public so others can use it, and (3) it is written to a standard
where the Cloudron team could adopt it as an official application.

It is the embedding companion to the Qdrant package (https://github.com/OrcVole/qdrant-cloudron):
TEI turns text into vectors, Qdrant stores and searches them. The two are packaged separately.

---

## 1. Golden rules (non-negotiable)

1. **Conformance first.** The Cloudron packaging rules in section 5 override convenience. A change
   that writes outside the allowed paths, runs as root, or skips the health check is wrong.
2. **Pin versions. Never use floating tags.** The upstream version lives in exactly one canonical
   place (the `TEI_VERSION` build argument and the pinned `@sha256` digest in `Dockerfile`). Both
   images are pinned by digest. See section 4. Never use the bare `:1.9`/`:latest` tags: those are
   CUDA images. The CPU build is the `cpu-` prefixed tag.
3. **Do not break the topology.** The embedding API and the docs are two surfaces with two security
   models. See section 6. Never place the Cloudron proxyAuth wall in front of the embedding API.
4. **Persisted state lives only in `/app/data`.** The model cache and the API key live there, which
   is what makes the Cloudron backup complete.
5. **Fail loud, log clearly.** `start.sh` fails fast and prints greppable `==>` markers.
6. **Every change updates its documentation.** Code and docs ship together.
7. **House style for prose:** Markdown and open formats only. No em dashes. Full words rather than
   contractions.
8. **Verify, do not assume.** When an upstream flag, image layout, env var, or Cloudron capability
   might have changed, check the live docs and confirm empirically. Record what you verified versus
   assumed (see docs/PACKAGING-NOTES.md).

---

## 2. What this repository is and is not

- It **is** a thin, reproducible packaging layer: a Dockerfile, an entrypoint, a manifest, and docs.
- It **is not** a fork of TEI. The binary is not patched. The package consumes the official release
  image and adapts only the runtime environment to Cloudron.
- Upstream owns the inference behaviour. This package owns the packaging, the security defaults, the
  topology, and the upgrade path.

---

## 3. Repository layout

```
.
├── AGENTS.md                  # this file: the contract
├── CONTRIBUTING.md            # dev workflow and the path to official inclusion
├── README.md                  # user-facing: topology, install, security
├── DESCRIPTION.md             # app store description
├── CHANGELOG.md               # package changelog (bracket [x.y.z] form)
├── POSTINSTALL.md             # shown after install
├── STATUS.md                  # build status & handoff (what is proven vs pending)
├── RECON.md                   # original recon and the full build plan
├── Dockerfile                 # multi-stage; canonical TEI_VERSION + MKL runtime copy
├── start.sh                   # entrypoint: prepare /app/data, generate the key, exec the router
├── CloudronManifest.json      # metadata, port, addons, healthCheckPath
├── CloudronVersions.json      # community publishing channel
├── logo.png                   # 512x512 icon (community mark, not HF branding)
├── .dockerignore              # keeps secrets and repo cruft out of the build context
├── .gitignore                 # keeps secrets out of git
├── docs/
│   ├── UPGRADING.md           # version policy and release gates
│   ├── DEBUGGING.md           # the runbook
│   ├── RELEASING.md           # the release procedure
│   ├── INTEGRATIONS.md        # connecting TEI to sibling apps and to Qdrant
│   ├── PACKAGING-NOTES.md     # running log of verified learnings
│   └── decisions/             # one short ADR per non-obvious decision
└── test/
    ├── smoke.sh               # local build + run + auth/inference assertions
    ├── lib.sh                 # shared backup/restore helpers (key + model survival)
    └── secret-scan.sh         # the pre-push anonymity sweep
```

---

## 4. Pinned versions and the single source of truth

**Canonical upstream version:** the `TEI_VERSION` build argument and the pinned `@sha256` digest on
the upstream `FROM` line in `Dockerfile`. The manifest mirrors the version in `upstreamVersion`. The
package `version` in the manifest is our own semver and moves independently.

| Component | Pin |
|---|---|
| TEI (upstream, CPU) | `cpu-1.9`, image `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9@sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07` (binary reports 1.9.3) |
| Cloudron base | `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c` (Ubuntu 24.04, glibc 2.39) |

The upstream CPU build is **amd64 only** (it bundles Intel MKL; there is no arm64 CPU image), so the
package targets amd64 hosts. See docs/decisions/0002-amd64-only.md.

The multi-stage build copies, out of the upstream image: the `text-embeddings-router` binary, the
`libfakeintel.so` LD_PRELOAD shim, the `/usr/local/lib/libmkl_*.so` math runtime, and `libiomp5.so`.
The non-obvious part: `libiomp5.so` is a symlink whose real soname is `libomp.so.5`, so it is
resolved at runtime through `LD_LIBRARY_PATH=/usr/local/lib` (not ldconfig, which would index it
under the wrong name); `cp -L` dereferences it into a concrete file. The Dockerfile runs a build-time
linkage gate, but the MKL libraries are dlopened at inference time and are NOT exercised by it, so a
runtime inference smoke (test/smoke.sh) is the real gate. See docs/decisions/0001-mkl-runtime-copy.md.

---

## 5. Cloudron conformance rules

- **Base image:** the final build stage is `cloudron/base`, pinned by digest. A multi-stage build
  copies the binary and its MKL runtime from the official upstream image (section 4).
- **Read-only root filesystem.** Only `/tmp`, `/run`, and `/app/data` are writable. The router writes
  only to its model cache (redirected to `/app/data`), `HF_HOME` (`/app/data/hf`), and its Unix
  socket under `/tmp`; it does not write to its working directory, so unlike some apps this package
  needs no `/run` working-directory shim.
- **Code under `/app/code`** (read-only at runtime). **State under `/app/data`** (the `localstorage`
  addon, the only backed-up location). Chown `/app/data` in `start.sh` before dropping privileges.
- **Run as the `cloudron` user** via `gosu cloudron:cloudron`. The `cloudron` user cannot bind
  privileged ports, so the listener is moved off the upstream default port 80 to 8080.
- **Health check:** `healthCheckPath` is `/health`, which returns 200 and is exempt from the API key
  (verified empirically). See docs/decisions/0003-health-and-port.md.
- **Instant usability:** no setup screen. The app works right after install (after the first-boot
  model download); the generated key is surfaced through `postInstallMessage`.

---

## 6. Architecture and topology (the crux)

TEI exposes its endpoints on one HTTP port (8080 in this package):

- **Embedding API** (`/embed`, `/v1/embeddings`, `/rerank`, `/info`): protected by the API key.
- **Health** (`/health`): open, no key, so Cloudron can monitor the app.
- **Interactive Swagger docs** (`/docs`): the only browsable surface; placed behind Cloudron login.

The package scopes the `proxyAuth` addon to `/docs` only, so Cloudron single sign-on guards the docs
UI while the embedding API stays open at the network level and is protected by the key. This is why
an unauthenticated API request returns TEI's own 401, not a login redirect. **Never** widen proxyAuth
to cover the embedding API. See docs/decisions/0004-proxyauth-on-docs.md.

TEI is insecure by default. The package generates one API key on first run (TEI has a single access
tier; there is no read-only key) and injects it through the `API_KEY` environment variable, so it
never appears in the process table. The key is stored at `/app/data/.secrets/keys.env` and is never
echoed to logs.

---

## 7. Configuration model

TEI is configured entirely by command-line flags and their environment-variable equivalents; there
is no operator config file to seed. `start.sh` owns the configuration:

- **Package-forced** (cannot be overridden by the operator): the listen host and port, the API key
  (from the secret file), the model cache and `HF_HOME` under `/app/data`, and `--hostname 0.0.0.0`
  passed on the command line (because the container's `HOSTNAME` env is set by the platform to the
  container id, which would otherwise make the router bind the wrong interface).
- **Operator-tunable** through the app's Environment: `TEI_MODEL_ID` (the model), and the optional
  `TEI_REVISION`, `TEI_POOLING`, `TEI_DTYPE`, `TEI_SERVED_MODEL_NAME`, `TEI_AUTO_TRUNCATE`,
  `TEI_HF_TOKEN`, `TEI_NUM_THREADS`, `TEI_HTTP_PORT`. The thread pool defaults to the cgroup CPU
  allotment.

First-run seeding (only the API key) is idempotent: it is written only when absent, so an update or
restart never clobbers it.

---

## 8. AI-debuggability requirements

- `start.sh` begins with `#!/bin/bash` and `set -euo pipefail`.
- Print phase markers to stdout, each prefixed with `==>`, so logs are greppable and distinguishable
  from the router's own lines.
- Echo the resolved runtime facts at startup (version, model, port, cache paths, key presence),
  never secrets.
- First-run seeding must be idempotent.
- All runtime state is files under `/app/data` (the model cache, `HF_HOME`, the key). If you add
  state, document it in docs/DEBUGGING.md under "State on disk".
- Deterministic build: no floating tags, no unpinned installs.
- Comments explain why, not what, especially Cloudron-specific workarounds.

---

## 9. Build, install, test, update

```bash
# Build and smoke-test locally (the Docker daemon is optional; rootless podman works)
test/smoke.sh

# Install or update on the target Cloudron (on-server build; no local Docker needed)
cloudron install --location tei.example.com --memory-limit 2G
cloudron update  --app tei.example.com

# Logs, exec, debug
cloudron logs -f --app tei.example.com
cloudron exec  --app tei.example.com
```

`test/smoke.sh` is the local gate (build links, the key gates the data plane, inference returns
real vectors on the Cloudron base). On a real box, confirm the model-download grace, the `/docs`
proxyAuth behaviour, update survival, and backup/restore key-and-model survival. A change is not done
until the relevant gate passes.

---

## 10. Path to official Cloudron inclusion

Reviewers look for: a clean multi-stage Dockerfile on the current base, correct read-only filesystem
handling, a working health check, instant usability with no setup screen, sensible default security,
a complete manifest with metadata and icon, and clear documentation. Keep the package thin and the
upstream unpatched. The community-app channel (`CloudronVersions.json`) is the route to make it
installable by others before any official review. See CONTRIBUTING.md.

---

## 11. Definition of done (pre-commit checklist)

- [ ] No write paths outside `/tmp`, `/run`, `/app/data` (verified on a real or local run).
- [ ] Runs as `cloudron`, not root.
- [ ] Upstream version pinned in exactly one canonical place; both images pinned by digest; the
      `cpu-` prefixed tag (never the CUDA tag).
- [ ] Topology unchanged, or the change is recorded in an ADR and README and re-verified.
- [ ] `start.sh` uses `set -euo pipefail` and prints `==>` markers; first-run seeding is idempotent.
- [ ] Health check returns 2xx and is unauthenticated.
- [ ] README, CHANGELOG, PACKAGING-NOTES, and DEBUGGING updated as relevant.
- [ ] `test/smoke.sh` passes; the relevant box gate passes on the target Cloudron.
- [ ] No secret, personal host, email, or token in any tracked file (the anonymity sweep in
      docs/RELEASING.md).
- [ ] Prose follows house style: no em dashes, full words, open formats.
```
