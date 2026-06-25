### Text Embeddings Inference is running

No setup wizard. On first boot it downloads the default model (`BAAI/bge-small-en-v1.5`, ready in
well under a minute) and starts serving. Get your API key below, then point your apps or your code
at it.

**Get your API key.** Open this app's Terminal (the `>_` button above) and run
`cat /app/data/.secrets/keys.env`. It prints `TEI_API_KEY`. Send it as an
`Authorization: Bearer` token on every request to the embedding endpoints.

**Embed some text (OpenAI-compatible).** From your own computer:
`curl $CLOUDRON-APP-ORIGIN/v1/embeddings -H "Authorization: Bearer PASTE-KEY-HERE" -H "content-type: application/json" -d '{"input":"hello world","model":"BAAI/bge-small-en-v1.5"}'`.
There is also a native endpoint, `POST /embed` with `{"inputs":"hello world"}`.

**Connect another Cloudron app** (OpenWebUI, AnythingLLM, n8n): in that app's settings, set the
OpenAI-compatible embeddings base URL to $CLOUDRON-APP-ORIGIN/v1 and paste the key as the API key.
Pair it with a Qdrant app to store the vectors it produces.

**Change the model.** Set `TEI_MODEL_ID` in this app's Environment to any TEI-compatible model id
(for example a larger embedding model, or a cross-encoder for `/rerank`) and restart. The new model
downloads on the next boot and is cached under `/app/data`.

**Good to know.** The default model does embeddings only; `/rerank` needs a reranker (cross-encoder)
model. The `/health` endpoint is open (Cloudron uses it to monitor the app); the interactive API
docs at $CLOUDRON-APP-ORIGIN/docs sit behind Cloudron login. The memory limit is 2 GB, which suits
small and medium models; raise it in Resources for a large model. Full details and integration
recipes are in the README.
