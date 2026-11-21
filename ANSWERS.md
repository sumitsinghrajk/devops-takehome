# Part 5 — Migrating ~40 ingress-nginx Ingresses to Gateway API

**Approach: run both side by side and shift traffic gradually. Never convert in place.**

1. **Inventory first.** List all Ingresses and every `nginx.ingress.kubernetes.io/*` annotation. Group them: plain host/path routing (easy) vs. rewrites, auth, rate limits, canary, snippets (hard).
2. **Install a Gateway API implementation in parallel** (its own GatewayClass and its own load balancer IP). ingress-nginx stays untouched and keeps serving.
3. **Convert** with a tool such as `ingress2gateway` for a first draft, then review by hand. Start with the lowest-risk services.
4. **Test without real traffic:** `curl --resolve host:443:<new-ip>` and compare responses with the old path.
5. **Shift traffic** with weighted DNS or load balancer weights (lower the TTL days earlier): 5% → 25% → 100%, watching error rate and latency, with rollback = move the weight back.
6. **Decommission** ingress-nginx only after a soak period.

**What I expect to break**
- Annotations with no direct equivalent: `configuration-snippet`, `auth-url`, rate limiting, body-size and timeout defaults.
- Path matching and regex/rewrite semantics differ.
- TLS: certificate secrets in other namespaces need a `ReferenceGrant`.
- Client IP / `X-Forwarded-For` handling, websockets, gRPC.
- Dashboards and alerts built on ingress-nginx metric names.
