### Text Embeddings Inference is running

**There is no web page to visit.** This app is an API, not a website. If you open its domain in a
browser you will see a blank page, and that is normal, not a fault. There is no dashboard or login
screen of its own. The only browsable page is the interactive API documentation at `/docs` (this
app's "Open" button goes there), which sits behind your Cloudron login.

**Get your API key.** Open this app's Terminal (the `>_` button above) and run
`cat /app/data/.secrets/keys.env`. It prints `TEI_API_KEY`. Send it as an `Authorization: Bearer`
token on every request to the embedding endpoints.

**Check it is working (in plain terms).** Two quick checks:

1. Liveness, no key needed: `curl $CLOUDRON-APP-ORIGIN/health` returns `OK`. If that works, the
   server is up.
2. A real embedding:
   `curl $CLOUDRON-APP-ORIGIN/v1/embeddings -H "Authorization: Bearer PASTE-KEY-HERE" -H "content-type: application/json" -d '{"input":"hello world","model":"BAAI/bge-small-en-v1.5"}'`

A working response is a long list of decimal numbers, like `[0.0152, -0.0226, 0.0085, ...]` (384 of
them). That wall of numbers IS the correct answer: it is the "embedding", the meaning of your text
turned into coordinates. It looks like gibberish to a person, and it is meant to: it is built for a
vector database such as Qdrant to compare and search, not for people to read. If instead you get
`401`, the key is missing or wrong. If you get numbers, it works.

**Connect another Cloudron app** (OpenWebUI, AnythingLLM, n8n): in that app's settings, set the
OpenAI-compatible embeddings base URL to $CLOUDRON-APP-ORIGIN/v1 and paste the key as the API key.
Pair it with a Qdrant app to store the vectors it produces.

**Change the model.** Set `TEI_MODEL_ID` in this app's Environment to any TEI-compatible model id
and restart. The new model downloads on the next boot and is cached under `/app/data`. The default
model does embeddings only; `/rerank` needs a reranker (cross-encoder) model.

**Good to know.** The memory limit is 2 GB, which suits small and medium models; raise it in
Resources for a large one. The interactive API docs are at $CLOUDRON-APP-ORIGIN/docs (behind Cloudron
login). Full details and integration recipes are in the README.
