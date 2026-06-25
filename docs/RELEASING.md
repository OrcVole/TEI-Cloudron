# Releasing

The repeatable release runbook. The package version and the upstream TEI version move independently:
the package version is plain semver in `CloudronManifest.json`; the upstream version is the
`TEI_VERSION` build argument and pinned digest in the `Dockerfile`, the single source of truth for the
binary that ships.

## Identity (every release)

All published artifacts use the neutral OrcVole identity and nothing else:

- Repository (public): `github.com/OrcVole/TEI-Cloudron`
- Image (public): `ghcr.io/orcvole/tei-cloudron`
- Commit author and committer: `OrcVole <OrcVole@users.noreply.github.com>`, unsigned

Run the anonymity sweep before every push (step 9). No personal host, email, username, internal URL,
path, or token may appear in any tracked file. A private personal mirror is a convenience only; its
URL must never appear in a tracked file.

## Prerequisites

- A container builder. Rootless `podman` is enough (no Docker daemon required).
- `skopeo` (to read the registry digest), `curl`, `jq`, and ImageMagick or Python+PIL (only if the
  icon changes).
- A GitHub Personal Access Token for OrcVole with `repo`, `write:packages`, and `read:packages`,
  kept in a gitignored and dockerignored file, deleted after the release.

## Release sequence

### 1. Bump versions

Change `TEI_VERSION` in the `Dockerfile` and the pinned `@sha256` digest on the same upstream `FROM`
line (both move together) to the new upstream CPU tag. Update `upstreamVersion` (the binary version,
which may differ from the tag) and bump `version` in `CloudronManifest.json`. Add a `[x.y.z]` entry
to `CHANGELOG.md` (the bracket form is required by `cloudron versions add`).

### 2. Gate 1: MKL linkage and inference (mandatory)

The binary is dynamically linked and dlopens the MKL runtime at inference time. The build-time
linkage gate covers only the direct dependencies, so the real gate is a runtime inference call:

```
test/smoke.sh        # builds the image, runs it Cloudron-style, asserts /embed returns a vector
```

If the build fails on a missing library, re-verify the MKL file list against the new upstream image
(docs/decisions/0001) and, if the glibc floor rose, raise the `cloudron/base` pin to a newer digest.
Re-pinning the base digest is part of this gate, not optional.

### 3. Gates 2 and 4: survival on a throwaway

On a throwaway test app: confirm the key and model cache survive `cloudron update` (Gate 2), then
clone from a backup into a fresh app and confirm the restored API key is byte-equal and the app
serves the expected dimensionality (Gate 4). Both were verified at the current pin.

### 4. Push the image

```
printf '%s' "$TOKEN" | podman login ghcr.io -u OrcVole --password-stdin
podman build -t ghcr.io/orcvole/tei-cloudron:<ver> -f Dockerfile .
podman push ghcr.io/orcvole/tei-cloudron:<ver>
```

### 5. Capture the registry digest (not the local one)

A local podman build reports a different manifest digest than the registry stores, so always read the
registry:

```
skopeo inspect --format '{{.Digest}}' docker://ghcr.io/orcvole/tei-cloudron:<ver>
```

### 6. Generate the versions entry and pin the digest

`cloudron versions add --state published` writes the new version into `CloudronVersions.json` (a
`version -> manifest-with-dockerImage` map). It enforces a stricter schema than install: a valid
`contactEmail`, a non-empty `iconUrl`, and a changelog in the literal `[x.y.z]` bracket form. Then
replace the recorded `dockerImage` tag with the `@sha256:` digest in BOTH `CloudronManifest.json`
(`dockerImage`) and `CloudronVersions.json` (`versions["<ver>"].manifest.dockerImage`). This is also
the step that fixes the placeholder `dockerImage` the repository carries before the first publish.

### 7. GHCR visibility

GHCR packages are private by default. The first publish needs a one-time manual flip to public
(profile, then Packages, then the package, then Package settings, then Danger Zone, then Change
visibility, then Public). There is no REST API for this. A normal version bump stays public. Do not
toggle repository visibility back and forth; it can trip a temporary lock.

### 8. Anonymous-pull-by-digest gate

Prove a stranger can pull the published image with no credentials, before pushing the repository:

```
podman rmi -f ghcr.io/orcvole/tei-cloudron@sha256:<digest>
podman logout ghcr.io
printf '{"auths":{}}' > /tmp/empty.json
podman pull --authfile /tmp/empty.json ghcr.io/orcvole/tei-cloudron@sha256:<digest>
```

An `unauthorized` result means the package is still private (fix step 7). Do not push the repository
until this passes.

### 9. Secret-scan and anonymity sweep (before any push)

Run `test/secret-scan.sh`. Confirm no token, key, personal host, email, internal URL, or path is in
any tracked file, and confirm it on the built image filesystem too (a gitignore does not protect the
Docker build context; only the dockerignore does).

### 10. Commit and push token-free

Commit as OrcVole, unsigned. Push with `GIT_ASKPASS` so no credential is written into git config or
the process arguments. Leave the named remote URL token-free.

### 11. Token cleanup

Delete the token file after the release and revoke the PAT if no near-term updates are planned.

### 12. The real community path (stranger-path gates, in order)

This is the only test that exercises what a stranger does. Run in this order and stop on any failure:

1. **Anonymous pull by digest** (step 8) passes.
2. **Digest byte-match:** the digest in `CloudronManifest.json` and `CloudronVersions.json` equals the
   registry digest from step 5.
3. **Versions-url install:** install a throwaway from the public versions URL on a spare subdomain
   (`cloudron install --versions-url <raw CloudronVersions.json URL> --location ...`), confirm the app
   log shows the image pulled by its digest, the app is healthy, the icon shows, and `/docs` is behind
   login while `/v1/embeddings` serves with the key.
4. **Uninstall** the throwaway and confirm the siblings on the box are untouched.

## The gates, in one place

1. MKL linkage and inference (Gate 1): `test/smoke.sh` builds on the pinned base and a real `/embed`
   call returns a vector. Mandatory on every bump (the build-time linkage gate alone does not load
   MKL).
2. Update survival (Gate 2): the key (byte-equal) and the model cache survive `cloudron update`.
3. Serve and auth (Gate 3): on a throwaway, health passes, the key gates the data plane, `/docs` is
   behind login.
4. Backup and restore (Gate 4): the API key is byte-equal and the model serves after a clone.
5. Anonymous pull: the published digest is pullable with no credentials.
6. Anonymity and secret sweep: no personal identifier or secret in any tracked file.
