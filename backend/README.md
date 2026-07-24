# backend/ — active (A9 / ADR-0010)

BADAN's MVP shipped with zero backend (ADR-0002). That posture is now narrowly amended: the
AI coach (A9) is an explicitly opt-in, feature-gated exception — see D-22 (`docs/DECISIONS.md`)
and ADR-0010. Every other surface (ingestion, scores, export generation) is still zero-network,
unchanged.

`api/` — the AI-coach backend: a stateless FastAPI proxy in front of a hosted LLM
(OpenRouter, `gpt-4o`). It holds no accounts and no user health data — retrieval and
conversation context stay on-device; this service only ever sees a query plus whatever
minimal context the client assembled for that one request. Deployed to the founder's own VPS
as an isolated service (see `infra/badan-api.service`, `infra/nginx/badan-api.conf`) —
separate systemd unit, separate unprivileged user, separate nginx vhost from every other
service on that host.

`workers/` — still dormant. No scheduled/background server-side work exists yet.
