# Integrations

How to use this TEI app as an embeddings provider, and how it pairs with a vector database to form a
self-hostable retrieval stack. Each recipe is marked with its verification level:

- **[verified live]** run end to end against the packaged app on a real Cloudron box.
- **[boundary verified]** the TEI call the integration makes is verified; the third-party side is a
  documented configuration, not driven here.

Throughout, `<tei>` is your TEI app domain and `<key>` is the API key from
`/app/data/.secrets/keys.env` (Terminal: `cat /app/data/.secrets/keys.env`).

## The two endpoints

TEI serves the same model two ways:

- **OpenAI-compatible:** `POST /v1/embeddings` with `{"input": "...", "model": "<served-model>"}`.
  Use this for anything that already speaks the OpenAI embeddings API. The `model` field must be the
  served model id (default `BAAI/bge-small-en-v1.5`) or empty; an arbitrary name is rejected.
- **Native:** `POST /embed` with `{"inputs": "..."}` or `{"inputs": ["...", "..."]}` (batch). Returns
  a bare array of vectors. Lower overhead, no `model` field.

```bash
# OpenAI-compatible
curl https://<tei>/v1/embeddings -H "Authorization: Bearer <key>" \
  -H 'content-type: application/json' \
  -d '{"input":"hello world","model":"BAAI/bge-small-en-v1.5"}'

# Native, batch
curl https://<tei>/embed -H "Authorization: Bearer <key>" \
  -H 'content-type: application/json' \
  -d '{"inputs":["first document","second document"]}'
```

## TEI + Qdrant: a retrieval round trip  [verified live]

This is the core of the stack: TEI turns text into vectors, Qdrant stores and searches them. Verified
end to end on a Cloudron box (TEI `BAAI/bge-small-en-v1.5`, 384-dim; Qdrant with Cosine distance):
the query "Which language emphasises safe memory management?" returned the Rust document at score
0.736, ahead of unrelated documents at 0.46 and 0.41.

The dimensionality must match: bge-small-en-v1.5 emits 384-dim vectors, so the Qdrant collection is
created with `size: 384`. If you change `TEI_MODEL_ID`, set the collection size to the new model's
embedding dimensionality. The reliable way to read it is the length of a vector returned by `/embed`
(`curl .../embed ... | python3 -c 'import sys,json;print(len(json.load(sys.stdin)[0]))'`); the model
card states it too. TEI's `GET /info` reports `max_input_length` (the token limit), which is a
different number, not the vector dimensionality.

```bash
# 1. Embed documents with TEI (native batch endpoint)
curl -s https://<tei>/embed -H "Authorization: Bearer <tei-key>" \
  -H 'content-type: application/json' \
  -d '{"inputs":["The Eiffel Tower is in Paris.","Rust focuses on memory safety."]}' > vecs.json

# 2. Create a Qdrant collection sized to the model (384 for bge-small)
curl -s -X PUT https://<qdrant>/collections/docs -H "api-key: <qdrant-key>" \
  -H 'content-type: application/json' -d '{"vectors":{"size":384,"distance":"Cosine"}}'

# 3. Upsert points (vector from step 1, plus your payload)
curl -s -X PUT 'https://<qdrant>/collections/docs/points?wait=true' -H "api-key: <qdrant-key>" \
  -H 'content-type: application/json' \
  -d '{"points":[{"id":1,"vector":[/* 384 floats */],"payload":{"text":"..."}}]}'

# 4. Embed the query with TEI, then search Qdrant with that vector
curl -s -X POST https://<qdrant>/collections/docs/points/search -H "api-key: <qdrant-key>" \
  -H 'content-type: application/json' \
  -d '{"vector":[/* query embedding */],"limit":3,"with_payload":true}'
```

A complete, runnable version of this round trip (Python, standard library only) is in
`config/examples/tei_qdrant_roundtrip.py`. It embeds, stores, searches, asserts the top match, and
deletes its throwaway collection.

## OpenWebUI: TEI as the embeddings engine  [boundary verified]

OpenWebUI can use an OpenAI-compatible endpoint for retrieval embeddings. In OpenWebUI:
Admin Settings, Documents (or Retrieval), set the embedding engine to "OpenAI", then:

- Base URL: `https://<tei>/v1`
- API key: `<key>`
- Embedding model: `BAAI/bge-small-en-v1.5` (the served model id)

The TEI side of this (an OpenAI `POST /v1/embeddings` with the served model id and the Bearer key) is
verified live. Drive the OpenWebUI UI yourself to complete it; rebuild its document index after
changing the embedding model, because vectors from a different model are not comparable.

## n8n: embeddings in a workflow  [boundary verified]

Use an HTTP Request node (or the OpenAI-compatible embeddings node) pointed at TEI:

- Method: POST, URL: `https://<tei>/v1/embeddings`
- Header: `Authorization: Bearer <key>`
- Body (JSON): `{"input": "={{ $json.text }}", "model": "BAAI/bge-small-en-v1.5"}`

Feed the returned `data[0].embedding` into a Qdrant node (or an HTTP Request to the Qdrant package)
to store or search. The TEI request is verified; the n8n nodes are standard.

## rig (Rust): a pure-Rust RAG client  [boundary verified]

`rig` speaks the OpenAI embeddings API, so point its OpenAI client at TEI's `/v1`:

```rust
// rig-core with the OpenAI provider; base URL set to the TEI app.
let client = rig::providers::openai::Client::from_url("<key>", "https://<tei>/v1");
let model = client.embedding_model("BAAI/bge-small-en-v1.5");
// Build embeddings, then upsert/search with rig-qdrant against the Qdrant package.
```

This keeps the data plane Rust end to end (TEI is Rust, Qdrant is Rust, rig is Rust). The TEI
endpoint and model id are verified; the exact rig API surface depends on the rig version you pin.

## agentgateway  [boundary verified]

agentgateway can route to an OpenAI-compatible embeddings backend. Configure a backend whose base URL
is `https://<tei>/v1` and whose bearer credential is `<key>`, then expose it to your agents. The TEI
endpoint is verified; the gateway routing is its own configuration.

## Choosing a model

The default `BAAI/bge-small-en-v1.5` (384-dim, English) is a good general default and pairs with the
Qdrant example. Set `TEI_MODEL_ID` (app Environment, then restart) to change it. For multilingual or
higher-recall needs, a larger bge or e5 model works but needs more memory (raise the app's limit).
For reranking (`/rerank`), set `TEI_MODEL_ID` to a cross-encoder such as `BAAI/bge-reranker-base`;
the default embedding model returns 424 on `/rerank`.
