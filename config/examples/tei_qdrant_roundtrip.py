#!/usr/bin/env python3
"""
TEI + Qdrant retrieval round trip — the core of the self-hostable RAG stack.

TEI (this package) turns text into vectors; Qdrant (the companion package) stores and searches them.
This script embeds a few documents with TEI, stores them in a throwaway Qdrant collection, embeds a
query, searches, asserts the expected top match, and deletes the throwaway collection.

Standard library only (urllib + json); no pip installs.

Configure with environment variables (no secrets are hardcoded):

    TEI_URL      e.g. https://tei.example.com
    TEI_KEY      the TEI API key (cat /app/data/.secrets/keys.env on the TEI app)
    QDRANT_URL   e.g. https://qdrant.example.com
    QDRANT_KEY   the Qdrant admin API key (cat /app/data/.secrets/keys.env on the Qdrant app)
    MODEL_ID     optional; the served TEI model id (default BAAI/bge-small-en-v1.5)

This recipe was verified end to end against the packaged apps: the query below returned the Rust
document well ahead of the unrelated ones.
"""
import json
import os
import sys
import urllib.error
import urllib.request

TEI_URL = os.environ.get("TEI_URL", "https://tei.example.com").rstrip("/")
QDRANT_URL = os.environ.get("QDRANT_URL", "https://qdrant.example.com").rstrip("/")
TEI_KEY = os.environ.get("TEI_KEY", "")
QDRANT_KEY = os.environ.get("QDRANT_KEY", "")
MODEL_ID = os.environ.get("MODEL_ID", "BAAI/bge-small-en-v1.5")
COLL = "tei_qdrant_example_DELETE_ME"


def req(url, method="GET", headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]


def tei_embed(inputs):
    """Native TEI /embed endpoint. Returns a list of vectors."""
    st, body = req(
        f"{TEI_URL}/embed", "POST",
        {"Authorization": f"Bearer {TEI_KEY}", "Content-Type": "application/json"},
        {"inputs": inputs},
    )
    if st != 200:
        sys.exit(f"TEI /embed failed: {st} {body}")
    return body


def main():
    if not (TEI_KEY and QDRANT_KEY):
        sys.exit("Set TEI_KEY and QDRANT_KEY (and TEI_URL / QDRANT_URL) in the environment.")

    docs = [
        "The Eiffel Tower is a wrought-iron lattice tower in Paris, France.",
        "Rust is a systems programming language focused on memory safety without a garbage collector.",
        "Photosynthesis converts sunlight into chemical energy stored in plant sugars.",
    ]
    query = "Which language emphasises safe memory management?"

    # 1. Embed the documents with TEI.
    vecs = tei_embed(docs)
    dim = len(vecs[0])
    print(f"1. TEI embedded {len(vecs)} docs, dim={dim} (model {MODEL_ID})")

    qhdr = {"api-key": QDRANT_KEY, "Content-Type": "application/json"}

    # 2. Create a throwaway Qdrant collection sized to the model. Cosine suits normalized embeddings.
    req(f"{QDRANT_URL}/collections/{COLL}", "DELETE", {"api-key": QDRANT_KEY})  # clear any stale one
    st, r = req(f"{QDRANT_URL}/collections/{COLL}", "PUT", qhdr,
                {"vectors": {"size": dim, "distance": "Cosine"}})
    print(f"2. Qdrant create collection: {st}")

    # 3. Upsert the document vectors with their text as payload.
    points = [{"id": i + 1, "vector": vecs[i], "payload": {"text": docs[i]}} for i in range(len(docs))]
    st, r = req(f"{QDRANT_URL}/collections/{COLL}/points?wait=true", "PUT", qhdr, {"points": points})
    print(f"3. Qdrant upsert {len(points)} points: {st}")

    # 4. Embed the query and search.
    qvec = tei_embed(query)[0]
    st, r = req(f"{QDRANT_URL}/collections/{COLL}/points/search", "POST", qhdr,
                {"vector": qvec, "limit": 3, "with_payload": True})
    hits = r["result"]
    print(f"4. Query: {query!r}")
    for h in hits:
        print(f"     score={h['score']:.3f}  {h['payload']['text'][:60]}")
    ok = "Rust" in hits[0]["payload"]["text"]
    print(f"   top match is the Rust document: {'YES' if ok else 'NO'}")

    # 5. Clean up the throwaway collection.
    st, r = req(f"{QDRANT_URL}/collections/{COLL}", "DELETE", {"api-key": QDRANT_KEY})
    print(f"5. Qdrant delete throwaway collection: {st}")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
