# Text Embeddings Inference (TEI) packaged for Cloudron.
#
# The upstream version is pinned by the TEI_VERSION build argument and, authoritatively, by the
# @sha256 digest on the `FROM ... AS upstream` line. The Cloudron manifest mirrors the version in
# `upstreamVersion`. See docs/UPGRADING.md before changing it (the linkage gate applies).
#
# Unlike the Qdrant package (a single self-contained binary), TEI's CPU build is a binary plus an
# Intel MKL runtime: ~320 MB of libmkl_*.so in /usr/local/lib, an Intel OpenMP shim (libiomp5.so,
# which upstream provides as a symlink to LLVM's libomp.so.5), and a libfakeintel.so that is
# LD_PRELOADed to make MKL select fast code paths on non-Intel CPUs. All of that is copied out of
# the pinned upstream image onto cloudron/base. The image is amd64-only: there is no arm64 CPU/MKL
# variant of text-embeddings-inference, so this package targets amd64 Cloudron hosts.

ARG TEI_VERSION=1.9

# --- Stage 1: the official upstream CPU image, used only as a source for the binary + MKL runtime.
# Pinned by digest (resolved 2026-06-25). Tag cpu-1.9 resolves to this digest. NOTE: the bare
# ":1.9"/":latest" tags are CUDA images; the CPU build is the "cpu-" prefixed tag.
FROM ghcr.io/huggingface/text-embeddings-inference:cpu-1.9@sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07 AS upstream

# Gather every runtime artifact into one tree, dereferencing symlinks (cp -L). The libiomp5.so in
# the upstream image is a symlink to ../llvm-14/lib/libomp.so.5; -L copies the real library out as
# a concrete file named libiomp5.so, which is the soname the MKL threading layer and the binary's
# DT_NEEDED both ask for.
RUN set -eux; \
    mkdir -p /gather/lib; \
    cp -L /usr/local/bin/text-embeddings-router /gather/text-embeddings-router; \
    cp -L /usr/local/libfakeintel.so            /gather/libfakeintel.so; \
    cp -L /usr/local/lib/*.so*                  /gather/lib/; \
    cp -L /lib/x86_64-linux-gnu/libiomp5.so     /gather/lib/libiomp5.so; \
    ls -l /gather /gather/lib

# --- Stage 2: the Cloudron app image -------------------------------------------------------------
# The final stage must be this exact base so the Cloudron file manager, web terminal, and log
# viewer work. Tag 5.0.0 resolves to this digest (Ubuntu 24.04, glibc 2.39). The upstream binary
# was built on Debian bookworm (glibc 2.36), which 2.39 satisfies (forward-compatible).
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# cloudron/base:5.0.0 already provides gosu, curl, openssl, ca-certificates, coreutils, and the
# binary's standard shared libs (libstdc++6, libssl3, libcrypto, libgcc_s, libm, libc). The only
# things not on the base are TEI's own binary and its MKL/OpenMP runtime, copied below; so no
# apt-get install is needed.

# The binary, the LD_PRELOAD shim, and the MKL + libiomp5 runtime. The MKL libraries are resolved
# at runtime via LD_LIBRARY_PATH (set below), NOT via ldconfig: libiomp5.so carries the internal
# soname "libomp.so.5", so an ldconfig cache would index it under the wrong name and a DT_NEEDED
# "libiomp5.so" would fail to resolve. LD_LIBRARY_PATH matches by filename, which is what works.
COPY --from=upstream /gather/text-embeddings-router /app/code/text-embeddings-router
COPY --from=upstream /gather/libfakeintel.so        /usr/local/libfakeintel.so
COPY --from=upstream /gather/lib/                    /usr/local/lib/
COPY start.sh /app/code/start.sh
RUN chmod 0755 /app/code/text-embeddings-router /app/code/start.sh

# Record the pinned upstream version in the image for debuggability and log output.
ARG TEI_VERSION
ENV TEI_VERSION=${TEI_VERSION}

# Runtime environment the binary needs. These mirror the upstream image's defaults: the libfakeintel
# preload, the MKL library search path, and the MKL instruction ceiling (MKL still gates on the real
# CPUID, so this is an upper bound, not a force — on a CPU without AVX-512 it falls back). They are
# overridable by the operator via the app's environment if a host CPU misbehaves.
ENV LD_PRELOAD=/usr/local/libfakeintel.so \
    LD_LIBRARY_PATH=/usr/local/lib \
    MKL_ENABLE_INSTRUCTIONS=AVX512_E4

# Linkage gate (build-time): fail the BUILD if the binary cannot resolve its DIRECT shared-library
# dependencies on this base, and confirm it executes. NOTE: the libmkl_*.so are loaded dynamically
# at inference time (they are not DT_NEEDED of the binary), so this gate does NOT exercise the MKL
# load path; that is covered by the runtime smoke test (test/smoke.sh / an actual /embed call).
RUN set -eux; \
    ldd /app/code/text-embeddings-router; \
    if ldd /app/code/text-embeddings-router 2>&1 | grep -qE 'not found'; then \
      echo "FATAL: unresolved shared library or glibc symbol on this base"; exit 1; \
    fi; \
    /app/code/text-embeddings-router --version

LABEL org.opencontainers.image.title="tei-cloudron" \
      org.opencontainers.image.description="HuggingFace Text Embeddings Inference packaged for Cloudron" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR /app/code

# start.sh runs as root, prepares /app/data, then drops to the cloudron user via gosu.
CMD [ "/app/code/start.sh" ]
