Text Embeddings Inference (TEI) is a fast, open-source server for text embeddings and reranking,
written in Rust by Hugging Face. It loads a sentence-transformer or reranker model and serves vector
embeddings over a simple REST API and an OpenAI-compatible `/v1/embeddings` endpoint, which makes it
a drop-in embeddings provider for retrieval-augmented generation, semantic search, and any client
that already speaks the OpenAI embeddings format.

This package runs TEI on Cloudron with a secure, single-domain topology:

- The embedding endpoints (`/embed`, `/v1/embeddings`, `/rerank`, `/info`) are protected by an API
  key, so programmatic clients and sibling apps authenticate with a key rather than being redirected
  to an interactive sign-in page.
- The liveness endpoint (`/health`) is open so Cloudron can health-check the app, and the
  interactive API documentation (`/docs`) is placed behind Cloudron login.

TEI has no authentication by default: anyone who can reach it can use it. This package closes that
gap. It generates a strong API key on first start and injects it through the environment so it never
appears in the process table.

The embedding model is downloaded on first boot and cached under the application data directory, so
Cloudron's backup covers it along with the generated key. The default model is `BAAI/bge-small-en-v1.5`
(384-dimensional English embeddings, about 130 MB); a different model can be served by setting
`TEI_MODEL_ID` in the app's environment.

This package targets amd64 Cloudron hosts: the upstream CPU build, which bundles the Intel MKL math
runtime, is published for amd64 only.

This is a community package. It tracks upstream Text Embeddings Inference releases and keeps the
upstream binary unmodified. Hugging Face, Text Embeddings Inference, and the names of any models are
trademarks of their respective owners. This package is community-maintained and is not affiliated
with or endorsed by Hugging Face.
