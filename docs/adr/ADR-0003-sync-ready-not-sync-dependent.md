# ADR-0003 — Sync-ready, not sync-dependent

- Status: Accepted
- Date: 2026-07-10

## Context

A future multi-device / E2E-sync world must not require a painful schema retrofit, but sync
must not leak into the MVP as complexity or a network dependency.

## Decision

Every row table carries, from day one: a ULID primary key (offline-generatable,
time-sortable), `updated_at`, `origin_device_id`, and a `deleted_at` tombstone. A reserved,
unused `sync_cursors` table exists. Provenance carries an `external_id` idempotency key and
every measurement table has a partial-unique identity index so re-ingest is a no-op.

No sync service, no oplog, no conflict resolution ships in MVP. All writes are synchronous and
local; **no write path may require the network.**

## Consequences

- Re-running ingestion is idempotent (proven by the identity indexes).
- Deletes are tombstones (except explicit user purge flows), preserving a future merge story.
- The cost is a few always-present columns — paid now, cheap; retrofitted later, expensive.
