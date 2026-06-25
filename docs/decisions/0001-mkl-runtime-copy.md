# 0001: Copy the Intel MKL runtime out of the upstream image onto cloudron/base

Status: accepted (built and inference-verified on cloudron/base, 2026-06-25)

## Context

The Qdrant sibling package copies a single self-contained binary onto `cloudron/base`. TEI's CPU
build is not self-contained: `text-embeddings-router` is dynamically linked and, at inference time,
dlopens an Intel MKL math runtime. Inspecting the upstream image (`cpu-1.9`):

- `ldd` on the binary needs `libstdc++`, `libssl`/`libcrypto`, `libgcc_s`, `libm`, `libc` (all on
  the base), plus `libiomp5.so` and a preloaded `libfakeintel.so`.
- The MKL libraries themselves, `/usr/local/lib/libmkl_*.so` (about 320 MB), are not DT_NEEDED of
  the binary. They are loaded at run time, selected by `libfakeintel.so` (which makes MKL pick fast
  code paths on non-Intel CPUs) under `MKL_ENABLE_INSTRUCTIONS=AVX512_E4`.
- `/lib/x86_64-linux-gnu/libiomp5.so` in the upstream image is a symlink to
  `../llvm-14/lib/libomp.so.5`, and that file's internal soname is `libomp.so.5`, not `libiomp5.so`.

## Decision

Multi-stage build. Stage one is the pinned upstream image, used only as a source. Copy out of it:
the binary, `libfakeintel.so`, all of `/usr/local/lib/*.so*` (the MKL libraries), and `libiomp5.so`
dereferenced with `cp -L` into a concrete file. Stage two is `cloudron/base`, which receives those
files and keeps the upstream runtime environment (`LD_PRELOAD=/usr/local/libfakeintel.so`,
`LD_LIBRARY_PATH=/usr/local/lib`, `MKL_ENABLE_INSTRUCTIONS=AVX512_E4`).

Resolve the MKL libraries through `LD_LIBRARY_PATH`, not `ldconfig`. If `ldconfig` indexed
`libiomp5.so`, it would record it under its internal soname `libomp.so.5`, and a DT_NEEDED of
`libiomp5.so` would then fail to resolve. `LD_LIBRARY_PATH` matches by filename, which is what the
binary and the MKL threading layer ask for. No `apt-get install` is needed: the base already provides
every standard library the binary links.

## Consequences

- Verified: `ldd` on the final image resolves every direct dependency, including
  `libiomp5.so => /usr/local/lib/libiomp5.so`, and `--version` runs.
- The build-time linkage gate proves only the DIRECT dependencies resolve; it does NOT load the
  dlopened MKL libraries. The real proof is a runtime inference call: `test/smoke.sh` asserts that
  `/embed` returns a vector on the assembled `cloudron/base` image, which exercises the MKL load
  path. This was confirmed both locally and live on a Cloudron box.
- The image carries about 320 MB of MKL libraries. That is inherent to the CPU build and is the cost
  of fast CPU inference.
- On an upstream bump, re-verify the file list (the MKL library names, `libfakeintel.so`, and the
  `libiomp5.so` symlink target can change) and re-run the inference smoke. See docs/UPGRADING.md.
