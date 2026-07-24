# infra/ — active for the AI-coach backend (A9 / ADR-0010)

`badan-api.service` — systemd unit for `backend/api`, hardened the same way as this
repo's sibling deployments (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
dedicated unprivileged `badan` user, `ReadWritePaths` scoped to `/srv/badan/data` only).

`nginx/badan-api.conf` — the isolated vhost for `badan.binjamshid.com`, proxying only to
`127.0.0.1:8010`. Does not touch any other vhost/service on the host. Port 80 redirects to
443 (except `/health`); the 443 block expects a certbot-managed cert already issued at the
standard `/etc/letsencrypt/live/badan.binjamshid.com/{fullchain,privkey}.pem` paths (run
`certbot --nginx -d badan.binjamshid.com` once on the VPS before reloading this vhost) —
D-22/ADR-0010's "own TLS cert" commitment. `limit_req_zone`/`limit_req` add a per-IP request
ceiling in front of `backend/api/main.py`'s own in-process rate limiters (defense in depth,
independent audit finding 2026-07-23), and `client_max_body_size` bounds request size ahead
of the app's own per-field Pydantic bounds.

Everything else BADAN does (ingestion, scores, export generation) stays local-first with no
infrastructure to provision, per ADR-0002 — this directory's scope is deliberately narrow to
the AI-coach exception, not a general backend buildout.
