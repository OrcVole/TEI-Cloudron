# Changelog

[1.0.1]
- Use the official Hugging Face mark as the app icon (was a custom graphic).
- Add `configurePath` `/docs` so the app's "Open" button goes to the interactive API docs (TEI has
  no dashboard of its own; this is the only browsable page).
- Post-install notes now state plainly that there is no web GUI and show how to verify it works
  (a successful embedding is a list of ~384 decimal numbers, which is the expected output).
- No image change: the dockerImage digest is unchanged from 1.0.0 (icon and notes are metadata).

[1.0.0]
- Initial release. Packages Hugging Face Text Embeddings Inference v1.9.3 (CPU build) on
  cloudron/base:5.0.0.
- Multi-stage Dockerfile copies the upstream binary plus its Intel MKL and OpenMP runtime onto the
  Cloudron base; a build-time linkage gate fails the build if a library or glibc symbol is missing.
- Generates a strong API key on first start and injects it through the environment (it never appears
  in the process table). The /embed, /v1/embeddings, /rerank, and /info endpoints require the key;
  /health is open for health checks and /docs is behind Cloudron login.
- OpenAI-compatible /v1/embeddings endpoint, so the app is a drop-in embeddings provider.
- Default model BAAI/bge-small-en-v1.5 (384-dim), overridable with TEI_MODEL_ID; the model cache
  and the key live under /app/data and are covered by Cloudron backup.
- amd64 only (the upstream CPU/MKL image has no arm64 variant).
