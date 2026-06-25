# Contributing

This repository is a thin, reproducible packaging layer for Text Embeddings Inference on Cloudron.
Read AGENTS.md first; it is the contract and it encodes the settled decisions.

## Development workflow

1. Build and smoke-test the image locally (the Docker daemon is optional; rootless podman works):

   ```
   test/smoke.sh
   ```

   This builds the image, runs it the way Cloudron does (root entrypoint, then `gosu cloudron`), and
   asserts the auth topology and that inference runs on `cloudron/base`. It needs a container engine
   and outbound network on first run (it downloads the default model, about 130 MB). Set
   `ENGINE=docker` to use Docker instead of podman.

2. Install or update on a throwaway Cloudron app (on-server build, no local Docker needed):

   ```
   cloudron install --location tei-test.example.com --memory-limit 2G
   cloudron update  --app tei-test.example.com
   ```

   For an on-server build before the first publish, the manifest's placeholder `dockerImage` must be
   removed (the on-server path builds from the Dockerfile and does not need a prebuilt image).

3. Run the gates that your change touches:
   - `test/smoke.sh` after any change to the Dockerfile, `start.sh`, or the upstream pin.
   - On a throwaway box: confirm the health check, the data-plane auth, and `/docs` behind login
     after a manifest or topology change; update survival after a `start.sh` change; backup/restore
     (key byte-equal, model serves) after a data-layout change. See docs/RELEASING.md for the gates.
   - `config/examples/tei_qdrant_roundtrip.py` to re-verify the Qdrant integration recipe.

4. Update the docs your change touches (AGENTS.md section 8 lists what), including
   docs/PACKAGING-NOTES.md with what you verified versus assumed. Docs are part of the deliverable: an
   AI or human picking this up relies on them, so a claim in a doc must be one you verified.

## House style

Markdown and open formats only. No em dashes. Full words rather than contractions. Scripts begin with
`set -euo pipefail` and print `==>` markers. Pin versions; never use a floating tag, and never the
bare `:1.9`/`:latest` (CUDA) tags.

## Releasing

See docs/RELEASING.md for the full procedure and the gate list. The upstream version lives only in the
`TEI_VERSION` build argument and the pinned digest; the manifest mirrors it in `upstreamVersion`.

## Path to official Cloudron inclusion

The community-app channel (`CloudronVersions.json`, installed with `cloudron install --versions-url`)
makes this installable by others before any official review. Reviewers look for a clean multi-stage
Dockerfile on the current base, correct read-only filesystem handling, a working health check, instant
usability, sensible default security, a complete manifest with an icon, and clear documentation. Keep
the package thin and the upstream unpatched.
