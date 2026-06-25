# 0002: Target amd64 only

Status: accepted (2026-06-25)

## Context

Cloudron runs on both amd64 and arm64 hosts, and a package ideally supports both. The Qdrant sibling
package's upstream image is a multi-arch index (amd64 + arm64), so it runs on either.

TEI publishes several image flavours. The CPU flavour used here, `cpu-1.9`, bundles the Intel MKL
math runtime (decision 0001), which is x86-64 only. Inspecting the upstream tag's manifest list shows
one usable platform, `linux/amd64`; the only other entry is `unknown/unknown`, which is a build
provenance attestation, not an arm64 image. TEI's arm64 support exists in other image flavours (for
example CUDA images target specific GPUs, and there are separate arm builds), but not for this CPU
MKL build.

## Decision

Target amd64 Cloudron hosts. Pin the amd64 CPU image by digest. State the limitation plainly in the
README, DESCRIPTION, and CHANGELOG, so an operator on an arm64 box is not surprised by a failed
install or a wrong-architecture pull.

## Consequences

- The package installs and runs on amd64 Cloudron hosts (the common case for self-hosting).
- On an arm64 host, the pinned image will not run. This is documented rather than worked around,
  because the MKL runtime has no arm64 equivalent in this image flavour.
- If a future requirement needs arm64, it is a separate packaging effort with a different upstream
  image flavour and a different math runtime (not MKL), and a different linkage gate. It is out of
  scope here and would be its own ADR.
