# 0003: Health check on /health, listener moved to port 8080

Status: accepted (verified on a live Cloudron box, 2026-06-25)

## Context

Cloudron health-checks an app by polling `healthCheckPath` and expects a 2xx, unauthenticated,
returning quickly and staying healthy. The app also listens on a single HTTP port that the platform
reverse-proxies; the container runs as the unprivileged `cloudron` user.

TEI's defaults (from `--help` and the image env): it listens on port 80, and it exposes `/health`
(liveness), `/info` (model metadata), `/metrics` (Prometheus, on a separate port 9000 by default),
and the embedding endpoints. When an `API_KEY` is set, requests must carry it as a bearer token.

Two facts had to be settled empirically: which endpoint is a valid health check when the key is set,
and whether the default port works for the `cloudron` user.

## Decision

- **Health check path is `/health`.** Verified with the key set: `GET /health` returns 200 with no
  authentication, while `/info` and the embedding endpoints return 401 without the key. So `/health`
  is the correct unauthenticated health path. It returns 200 once the HTTP server is up, which the
  router reaches only after the model has loaded and warmed up, so a 200 also means the app is
  actually ready to serve, not merely listening.
- **Listener moved to 8080.** The `cloudron` user cannot bind privileged ports (< 1024), and the
  upstream default is 80. `start.sh` passes `--port 8080` and the manifest's `httpPort` is 8080.
- **Hostname forced to 0.0.0.0 on the command line.** The router's `--hostname` defaults to the
  `HOSTNAME` environment variable, which Docker and Cloudron set to the container id. Left alone the
  router would try to bind that as an interface. `start.sh` passes `--hostname 0.0.0.0` explicitly,
  which overrides the env default.

## Consequences

- Verified live: on install and after an update, Cloudron's health check passed; `/health` returns
  200 unauthenticated through the Cloudron proxy.
- First boot downloads the model before `/health` turns 200. For the default model this was about 9
  to 10 seconds on the box, inside Cloudron's health grace. A LARGE model takes longer; the README
  tells operators to expect a slower first boot and to raise resources. If a future default model
  were large enough to exceed the grace, the health path would need to decouple liveness from model
  readiness (TEI does not expose a separate "listening but not ready" endpoint today), which would be
  a new decision.
- `/metrics` stays on its own port (9000) and is not exposed through the Cloudron httpPort, so it is
  not reachable from outside the container. That is acceptable: metrics are an internal concern here.
