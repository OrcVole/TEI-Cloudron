# 0004: Scope proxyAuth to /docs only, and without supportsBearerAuth

Status: accepted (verified on a live Cloudron box, 2026-06-25)

## Context

TEI serves everything on one HTTP port. The endpoints split by purpose: the embedding API (`/embed`,
`/v1/embeddings`, `/rerank`, `/info`) is protected by TEI's API key; `/health` is open for
monitoring; and `/docs` is an interactive Swagger UI, the only browsable surface. On Cloudron, the
`proxyAuth` addon places Cloudron single sign-on in front of a chosen path.

The embedding API carries programmatic traffic that cannot complete an interactive login, so it must
stay in front of Cloudron SSO and be protected by the key (an unauthenticated call must return TEI's
own 401, not a login redirect). The only thing that benefits from SSO is the human-facing `/docs`.

## Decision

Scope proxyAuth to `/docs` only, and do NOT set `supportsBearerAuth`:

    "addons": { "proxyAuth": { "path": "/docs" } }

This puts Cloudron SSO in front of the Swagger UI and leaves every other path open at the network
level (protected by the API key where it matters). Declare it from first install, because Cloudron
cannot add proxyAuth to an existing app later.

### Why no supportsBearerAuth (the contrast with the Qdrant package)

`supportsBearerAuth: true` tells proxyAuth to forward any request carrying an `Authorization: Bearer`
header instead of redirecting it to login. It is meant for a proxyAuth path that also fronts a
Bearer-authenticated API, so that API clients are not redirected.

The Qdrant sibling package sets it on its `/dashboard` wall, with the rationale that forwarding a
key-bearing request to the dashboard grants nothing the key does not already grant. That rationale
relies on the key gating what is behind the wall. It does NOT transfer to TEI: nothing key-related
sits under `/docs` (the Bearer-authenticated embedding API is on the open plane, not under `/docs`),
so `supportsBearerAuth` here buys nothing and only weakens the wall. Verified on the box: with the
flag set, a request with ANY bearer header (even `Bearer anythingatall`) skipped the SSO login on
`/docs` (303 to the app instead of 302 to `/login`). Removed it; re-verified after `cloudron update`
that a bogus bearer now gets a 302 to login. The Swagger "Try it out" feature is unaffected, because
its calls go to the embedding API on the open plane, not through the `/docs` wall.

## Consequences

- `/docs` is reachable only by a logged-in Cloudron user. The embedding API returns TEI's own 401
  when unauthenticated, so programmatic clients and sibling apps authenticate with the key.
- Swagger still works behind the wall: verified that the OpenAPI spec at `/api-doc/openapi.json` is
  open (200) and the `/docs/*` UI assets load with the SSO cookie, so a logged-in user's docs page
  renders and its spec fetch succeeds. The OpenAPI schema being open is acceptable: it is public API
  shape, not data.
- Never widen proxyAuth to cover the embedding API; that would redirect clients to a login page and
  break every integration.
