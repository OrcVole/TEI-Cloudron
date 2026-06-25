# Debugging

The runbook for a broken or misbehaving TEI deploy. Read the boot ladder first; most problems are
visible in the logs.

```bash
cloudron logs -f --app <app>     # follow logs
cloudron exec    --app <app>     # shell into the running container
cloudron debug   --app <app>     # pause the app, mount the filesystem read-write
```

## The boot ladder (what a healthy start looks like)

Every package-emitted line is prefixed with `==>`. A healthy first boot prints, in order:

```
==> [start] text-embeddings-inference <ver> booting
==> [start] preparing /app/data (model cache, hf home, secrets)
==> [start] first run: generating API key            # first boot only; later: "existing API key found"
==> [start] API key stored at /app/data/.secrets/keys.env
==> [start] cgroup memory.max=<bytes> bytes
==> [start] model    : BAAI/bge-small-en-v1.5
==> [start] http     : 0.0.0.0:8080 (/embed, /v1/embeddings; /health and /docs are open)
==> [start] cache    : /app/data/hub (first boot downloads the model here)
==> [start] hf_home  : /app/data/hf
==> [start] threads  : <n> (rayon + tokenization)
==> [start] api key  : present
==> [start] exec text-embeddings-router <ver>
```

Then the router logs (not `==>` prefixed): `Downloading ...` (first boot), `Model artifacts
downloaded in ...`, `Starting HTTP server: 0.0.0.0:8080`, `Ready`. The app passes the health check
once `Ready` prints.

## State on disk (all under /app/data, all backed up)

| Path | What | Notes |
|---|---|---|
| `/app/data/.secrets/keys.env` | The generated API key (`TEI_API_KEY=...`) | 0600, owned by cloudron. Written once on first boot; never reseeded. |
| `/app/data/hub` | Hugging Face model cache | Where the model is downloaded. Survives restart/update/restore, so the model is not re-downloaded. |
| `/app/data/hf` | `HF_HOME` (token, misc HF state) | Holds an HF token if you set one for gated models. |
| `/app/data/.initialized` | First-run marker | Touched after first-run setup. |

If you add runtime state, it must live under `/app/data` and be documented here.

## Common failures and their signatures

### The app never becomes healthy on first install

- **Model still downloading.** Large models take minutes; the log shows `Downloading onnx/model.onnx`
  without a following `Ready`. The default model is small (ready in about 10 s on a typical box). If
  you set `TEI_MODEL_ID` to a large model, expect a slow first boot and raise the app's resources.
  The model downloads once and is cached, so subsequent boots are fast.
- **No network / Hugging Face unreachable.** The download stalls or errors. TEI needs outbound
  network on first boot for the chosen model. Check the box's egress.
- **Gated or private model.** The download returns 401/403. Set `TEI_HF_TOKEN` in the app's
  Environment to a Hugging Face token with access, and restart.

### `Illegal instruction` / the router crashes immediately at warmup

The MKL math runtime selects CPU instruction paths. The package ships
`MKL_ENABLE_INSTRUCTIONS=AVX512_E4` and the `libfakeintel.so` preload (the upstream CPU defaults). If
the host CPU lacks a needed instruction and the build crashes with SIGILL, override the env in the
app's Environment to a lower ceiling (for example `MKL_ENABLE_INSTRUCTIONS=AVX2`) and restart. This
was not observed on the test box, but it is the first thing to try on an old or unusual CPU.

### Every API call returns 401

That is correct when no key, or the wrong key, is sent. Read the key with
`cloudron exec --app <app> -- cat /app/data/.secrets/keys.env` and send it as
`Authorization: Bearer <key>`. Remember `/health` and `/docs` are the only paths that do not need the
key.

### `/rerank` returns 424

The configured model is an embedding model, not a reranker. `/rerank` needs a cross-encoder
(sequence-classification) model. Set `TEI_MODEL_ID` to one (for example `BAAI/bge-reranker-base`) and
restart.

### `/docs` redirects to login and you expected it open

That is by design: `/docs` (the Swagger UI) is behind Cloudron single sign-on. Sign in as a Cloudron
user. The embedding API is the open, key-protected surface; `/docs` is the human surface. See
docs/decisions/0004-proxyauth-on-docs.md.

### OpenAI client rejects the `model` field

`POST /v1/embeddings` requires `model` to be the served model id (default `BAAI/bge-small-en-v1.5`)
or empty. An arbitrary name returns an error naming the correct id. Use the served id, or set
`TEI_SERVED_MODEL_NAME` to the name your client insists on sending.

## Restoring from a backup

Cloudron backs up `/app/data`, which holds the key and the model cache. A restore (or a
`cloudron clone`) brings back the byte-identical key (so existing clients keep working) and the
cached model (so no re-download). Verified on a box: after a clone, the restored key was byte-equal
and the app served immediately. There is no database to reconcile.

## Rebuilding cleanly

`cloudron update` rebuilds from the Dockerfile (on-server build) and takes a pre-update backup first.
If a build breaks, the pre-update backup is the rollback. The model cache and the key survive the
rebuild because they are under `/app/data`, which is not part of the image.
